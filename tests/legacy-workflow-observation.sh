#!/usr/bin/env bash
# Preserve complete observed policies plus the proven validation retirements.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'legacy-workflow-observation: %s\n' "$*" >&2; exit 1; }
fixture="$root/tests/fixtures/legacy-workflow-rulesets-observed.jsonl"
[[ "$(sha256sum "$fixture" | cut -d ' ' -f 1)" == 5c5af141f3cae99c705575a10d2c511ca7c2561b04e2a39b9e3002a05a927bf0 ]] ||
  fail 'captured native policies changed; rebind observation before adoption'
jq -se 'length==6 and ([.[].rulesetId]|unique|length)==6 and
  all(.[]; .forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId==948529001)' "$fixture" >/dev/null ||
  fail 'incomplete native policy inventory'
# Compare the complete rendered JSON array in $1 with the captured policies,
# allowing only the explicitly reviewed source, encoding and retirement changes.
check_rules() {
  jq -e --slurpfile baseline "$fixture" '
    def expected:
      {managementPolicies:(if .managementPolicies==["Observe"] then ["Observe","Update"] else .managementPolicies end),
       forProvider:(.forProvider
         | if .name=="Require workflow - Go template validation" or .name=="Require workflow - .NET template tests"
           then .enforcement="disabled" else . end
         | if .name=="Require workflow - .NET template tests" or .name=="Require workflows to pass before merging for .NET"
           then .enforcement="disabled" | .rules |= map(del(.requiredWorkflows)) else . end
         | if has("bypassActors") then .bypassActors |= map(
             if .actorType=="OrganizationAdmin" and .actorId==0 then del(.actorId) else . end) else . end
         | .conditions[0].refName[0].exclude=[]
         | if (.rules[0].requiredWorkflows // [] | length)>0 then .rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId=933213756 else . end),
       providerConfigRef:{kind:"ProviderConfig",name:"default"}};
    . as $render | type=="array" and
    ([.[] | select(.kind=="OrganizationRuleset") |
      .spec.forProvider.rules[]?.requiredWorkflows[]?.requiredWorkflow[]? |
      select(.repositoryId==948529001)] | length==0) and all($baseline[];
      . as $old | ($old | expected) as $expected |
      [$render[] | select(.kind=="OrganizationRuleset" and
        (.metadata.name==$old.name or .spec.forProvider.name==$old.forProvider.name or
          .metadata.annotations["crossplane.io/external-name"]==($old.rulesetId|tostring)))] |
      length==1 and (.[0] |
        .apiVersion=="enterprise.github.m.upbound.io/v1alpha1" and
        .metadata.name==$old.name and (.metadata|has("namespace")|not) and
        .metadata.annotations["crossplane.io/external-name"]==
          (if $old.managementPolicies==["Observe"] then ($old.rulesetId|tostring) else null end) and
        .spec==$expected))
  ' "$1" >/dev/null 2>&1
}
# Require the workflow at $1 to invoke the observation test unconditionally in
# the required manifest job. Return failure for missing or bypassable coverage.
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || return 1
  jq -e '[.[] | select(.run=="bash tests/legacy-workflow-observation.sh")]
    | length==1 and (.[0]|has("if")|not) and (.[0]|has("continue-on-error")|not)' <<<"$steps" >/dev/null
}
kubectl kustomize "$root/deploy" >"$work/render.yaml" || fail 'render failed'
yq -o=json -I=0 '.' "$work/render.yaml" | jq -s '.' >"$work/render.json" || fail 'incomplete rendered input'
check_rules "$work/render.json" || fail 'policy differs from complete native observation and reviewed source switch'
check_ci "$root/.github/workflows/ci.yaml" || fail 'missing unconditional required-job invocation'
mutations=(
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies = ["Observe"]'
  '.spec.managementPolicies += ["Create"]'
  '.spec.managementPolicies += ["LateInitialize"]'
  '.spec.managementPolicies = ["*"]'
  '.metadata.annotations["crossplane.io/external-name"] = "123"'
  '.metadata.namespace = "another-namespace"'
  '.spec.forProvider.enforcement |= (if .=="active" then "disabled" else "active" end)'
  '.spec.forProvider.target = "tag"'
  'del(.spec.forProvider.rules)'
  'del(.spec.forProvider.conditions)'
  '.spec.forProvider.conditions[0].refName[0].include = ["~ALL"]'
  '.spec.forProvider.bypassActors += [{"actorId":123,"actorType":"Team","bypassMode":"always"}]'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId = 948529001'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path = ".github/workflows/other.yaml"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref = "refs/heads/other"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].doNotEnforceOnCreate |= not'
)
count=0
while IFS= read -r name; do
  for mutation in "${mutations[@]}"; do
    jq --arg name "$name" "map(if .kind==\"OrganizationRuleset\" and .metadata.name==\$name then ($mutation) else . end)" \
      "$work/render.json" >"$work/mutated.json"
    if check_rules "$work/mutated.json"; then fail "accepted $mutation on $name"; fi
    count=$((count + 1))
  done
  jq --arg name "$name" '. + [.[] | select(.kind=="OrganizationRuleset" and .metadata.name==$name)]' \
    "$work/render.json" >"$work/mutated.json"
  if check_rules "$work/mutated.json"; then fail "accepted duplicate adoption for $name"; fi
  count=$((count + 1))
done < <(jq -r '.name' "$fixture")
{ printf '%s\n' "$(<"$work/render.json")"; printf '{'; } >"$work/incomplete.json"
if check_rules "$work/incomplete.json"; then fail 'accepted complete prefix followed by decode failure'; fi
jq '. + [{kind:"OrganizationRuleset",metadata:{name:"unregistered-legacy-rule"},spec:{forProvider:{rules:[{requiredWorkflows:[{requiredWorkflow:[{repositoryId:948529001}]}]}]}}}]' \
  "$work/render.json" >"$work/mutated.json"
if check_rules "$work/mutated.json"; then fail 'accepted an additional legacy workflow source'; fi
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/legacy-workflow-observation.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/legacy-workflow-observation.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/legacy-workflow-observation.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" >"$work/ci.yaml"
  if check_ci "$work/ci.yaml"; then fail 'accepted weakened required CI invocation'; fi
done
printf 'legacy-workflow-observation: complete native policies preserved; %s rejection controls passed\n' "$((count + 5))"
