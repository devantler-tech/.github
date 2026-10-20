#!/usr/bin/env bash
# Preserve read-only adoption of existing workflow policies before their source moves.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'legacy-workflow-observation: %s\n' "$*" >&2; exit 1; }
check_rules() {
  jq -e '
    def binding($name; $id; $title):
      [.[] | select(.kind == "OrganizationRuleset" and
        (.metadata.name == $name or .metadata.annotations["crossplane.io/external-name"] == $id))]
      | length == 1 and (.[0] |
        .apiVersion == "enterprise.github.m.upbound.io/v1alpha1" and
        .metadata.name == $name and (.metadata | has("namespace") | not) and
        .metadata.annotations["crossplane.io/external-name"] == $id and
        .spec == {managementPolicies:["Observe"],
          forProvider:{name:$title,target:"branch",enforcement:"active"},
          providerConfigRef:{kind:"ProviderConfig",name:"default"}});
    type == "array" and
    binding("require-workflows-auto-merge"; "3716878";
      "Require workflows to pass before merging - EnableAutoMerge") and
    binding("require-workflows-vulnerability-scan"; "14426226";
      "Require workflows to pass before merging - ScanGitHubActions") and
    binding("require-workflows-dotnet"; "3716863";
      "Require workflows to pass before merging for .NET")
  ' "$1" >/dev/null 2>&1
}
kubectl kustomize "$root/deploy" >"$work/render.yaml" || fail 'render failed'
yq -o=json -I=0 '.' "$work/render.yaml" | jq -s '.' >"$work/render.json" ||
  fail 'incomplete rendered input'
check_rules "$work/render.json" || fail 'missing, duplicate or write-enabled observer'
for name in require-workflows-auto-merge require-workflows-vulnerability-scan require-workflows-dotnet; do
  for authority in Create Update Delete LateInitialize '*'; do
    jq --arg name "$name" --arg authority "$authority" '
      map(if .kind == "OrganizationRuleset" and .metadata.name == $name
        then .spec.managementPolicies += [$authority] else . end)
    ' "$work/render.json" >"$work/mutated.json"
    if check_rules "$work/mutated.json"; then fail "accepted $authority on $name"; fi
  done
  jq --arg name "$name" 'map(if .kind == "OrganizationRuleset" and .metadata.name == $name
    then .metadata.annotations["crossplane.io/external-name"] = "123" else . end)' \
    "$work/render.json" >"$work/mutated.json"
  if check_rules "$work/mutated.json"; then fail "accepted a substituted identity for $name"; fi
  jq --arg name "$name" '. + [.[] | select(.kind == "OrganizationRuleset" and .metadata.name == $name)]' \
    "$work/render.json" >"$work/mutated.json"
  if check_rules "$work/mutated.json"; then fail "accepted duplicate adoption for $name"; fi
done
printf '[]\n{' >"$work/incomplete.json"
if check_rules "$work/incomplete.json"; then fail 'accepted a plausible prefix followed by decode failure'; fi
steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$root/.github/workflows/ci.yaml")" ||
  fail 'unreadable CI'
jq -e '[.[] | select(.run == "bash tests/legacy-workflow-observation.sh")]
  | length == 1 and (.[0] | has("if") | not)
    and (.[0] | has("continue-on-error") | not)' <<<"$steps" >/dev/null ||
  fail 'missing unconditional required-job invocation'
printf 'legacy-workflow-observation: read-only imports and 22 rejection controls passed\n'
