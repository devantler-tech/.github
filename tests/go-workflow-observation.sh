#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  printf 'go-workflow-observation: %s\n' "$*" >&2
  return 1
}
# The captured complete live policy is independent of the desired manifest.
# Permit only its reviewed source-repository replacement and safe ID-less bypass encoding.
fixture="$root/tests/fixtures/go-workflow-ruleset-observed.json"
fixture_hash="$(sha256sum "$fixture" | cut -d ' ' -f 1)"
[[ "$fixture_hash" == 70b116550ab2adaf1d55a5e8a622536e12245ea65387817713045f3adfc44c66 ]] || {
  fail 'observed policy fixture changed; rebind the complete live policy before adoption'
  exit 1
}
expected="$(jq -ce '
  if .rulesetId != 10320335 or
      .forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId != 948529001 then
    error("wrong observed identity or legacy source")
  else {
    managementPolicies:["Observe","Update"],
    forProvider:(.forProvider
      | .bypassActors |= map(if .actorType == "OrganizationAdmin" and .actorId == 0 then del(.actorId) else . end)
      | .rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId = 933213756),
    providerConfigRef:{kind:"ProviderConfig",name:"default"}
  } end' "$fixture")"
check_rule() {
  local observed
  observed="$(yq -o=json -I=0 '.' "$1" | jq -s '[.[] | select(.kind == "OrganizationRuleset" and (.metadata.name == "require-workflows-go" or .metadata.annotations["crossplane.io/external-name"] == "10320335"))]')" || {
    fail 'unreadable render'
    return 1
  }
  jq -e --argjson expected "$expected" '
    length == 1 and .[0].apiVersion == "enterprise.github.m.upbound.io/v1alpha1"
    and .[0].metadata.name == "require-workflows-go"
    and (.[0].metadata | has("namespace") | not)
    and .[0].metadata.annotations["crossplane.io/external-name"] == "10320335"
    and .[0].spec == $expected
  ' <<<"$observed" >/dev/null || {
    fail 'unexpected Go observation policy'
    return 1
  }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || {
    fail 'unreadable CI'
    return 1
  }
  jq -e '[.[] | select(.run == "bash tests/go-workflow-observation.sh")]
    | length == 1 and (.[0] | has("if") | not)
      and (.[0] | has("continue-on-error") | not)' <<<"$steps" >/dev/null || {
    fail 'missing unconditional CI guard'
    return 1
  }
}
kubectl kustomize "$root/deploy" >"$work/render.yaml" || {
  fail 'render failed'
  exit 1
}
check_rule "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
# Mutate the real rendered policy. Update is allowed only with the complete
# captured policy backfilled; no other authority or policy change is admitted.
mutations=(
  'del(.spec.managementPolicies)'
  '.spec.managementPolicies = ["Observe"]'
  '.spec.managementPolicies += ["Create"]'
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies += ["LateInitialize"]'
  '.spec.managementPolicies = ["*"]'
  '.metadata.annotations."crossplane.io/external-name" = "123"'
  'del(.metadata.annotations."crossplane.io/external-name")'
  '.metadata.name = "another-import"'
  '.metadata.namespace = "another-namespace"'
  '.spec.forProvider.name = "another-rule"'
  '.spec.forProvider.target = "tag"'
  '.spec.forProvider.enforcement = "disabled"'
  'del(.spec.forProvider.rules)'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId = 948529001'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path = ".github/workflows/other.yaml"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref = "refs/heads/other"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow += [{"repositoryId":123,"path":"other.yaml","ref":"refs/heads/main"}]'
  '.spec.forProvider.rules[0].requiredWorkflows[0].doNotEnforceOnCreate = false'
  '.spec.forProvider.rules[0].requiredSignatures = true'
  'del(.spec.forProvider.conditions)'
  '.spec.forProvider.conditions = [{"repositoryName":[{"include":["~ALL"],"exclude":[]}]}]'
  '.spec.forProvider.conditions[0].refName[0].include = ["~ALL"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].name = "other"'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].propertyValues = ["Rust"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].source = "custom"'
  '.spec.forProvider.bypassActors = []'
  '.spec.forProvider.bypassActors[0].actorId = 0'
  '.spec.forProvider.bypassActors[0].actorType = "Team"'
  '.spec.forProvider.bypassActors[0].bypassMode = "pull_request"'
  '.spec.forProvider.bypassActors += [{"actorId":123,"actorType":"Integration","bypassMode":"always"}]'
  '.apiVersion = "repo.github.m.upbound.io/v1alpha1"'
  '.spec.providerConfigRef.name = "another-provider"'
  '.spec.providerConfigRef.kind = "ClusterProviderConfig"'
)
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-workflows-go")'
for mutation in "${mutations[@]}"; do
  yq "($selector) |= ($mutation)" "$work/render.yaml" >"$work/bad.yaml"
  if check_rule "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
    fail "accepted mutation $mutation"
    exit 1
  fi
  grep -qF 'unexpected Go observation policy' "$work/diagnostic"
done
# A second name must not adopt the same external identity.
yq "[$selector | .metadata.name = \"duplicate-go-import\"] + [.] | .[]" "$work/render.yaml" >"$work/bad.yaml"
if check_rule "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
  fail 'accepted duplicate external identity'
  exit 1
fi
grep -qF 'unexpected Go observation policy' "$work/diagnostic"
yq "del($selector)" "$work/render.yaml" >"$work/bad.yaml"
if check_rule "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
  fail 'accepted missing import'
  exit 1
fi
grep -qF 'unexpected Go observation policy' "$work/diagnostic"
# Plausible output followed by a reader failure is not successful evidence.
mkdir "$work/bin"
real_yq="$(command -v yq)"
cat >"$work/bin/yq" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_YQ" "$@"
exit 42
WRAPPER
chmod +x "$work/bin/yq"
if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" check_rule "$work/render.yaml" >"$work/diagnostic" 2>&1; then
  fail 'accepted failed reader'
  exit 1
fi
grep -qF 'unreadable render' "$work/diagnostic"
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-observation.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-observation.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-observation.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" >"$work/ci.yaml"
  if check_ci "$work/ci.yaml" >"$work/diagnostic" 2>&1; then
    fail 'accepted weakened CI guard'
    exit 1
  fi
  grep -qF 'missing unconditional CI guard' "$work/diagnostic"
done
printf 'go-workflow-observation: PASS; canonical policy preserves observed protections; %s rejection controls\n' "$((${#mutations[@]} + 6))"
