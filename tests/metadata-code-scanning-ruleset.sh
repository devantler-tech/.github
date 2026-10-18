#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'metadata-code-scanning-ruleset: %s\n' "$*" >&2; return 1; }
expected='{"managementPolicies":["Observe","Create","Update","LateInitialize"],"forProvider":{"name":"Require code scanning results - Metadata","target":"branch","enforcement":"active","bypassActors":[],"conditions":[{"refName":[{"include":["~DEFAULT_BRANCH"],"exclude":[]}],"repositoryName":[{"include":[".github","monorepo"],"exclude":[]}]}],"rules":[{"requiredCodeScanning":[{"requiredCodeScanningTool":[{"tool":"CodeQL","alertsThreshold":"all","securityAlertsThreshold":"all"}]}]}]},"providerConfigRef":{"kind":"ProviderConfig","name":"default"}}'
check_rule() {
  local observed
  observed="$(yq -o=json -I=0 '.' "$1" | jq -s '[.[] | select(.kind == "OrganizationRuleset" and .metadata.name == "require-metadata-code-scanning-results")]')" || { fail 'unreadable render'; return 1; }
  jq -e --argjson expected "$expected" '
    length == 1 and .[0].apiVersion == "enterprise.github.m.upbound.io/v1alpha1"
    and .[0].spec == $expected
    and ((.[0].metadata.annotations // {}) | has("crossplane.io/external-name") | not)
  ' <<< "$observed" >/dev/null || { fail 'unexpected CodeQL policy'; return 1; }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || { fail 'unreadable CI'; return 1; }
  jq -e '[.[] | select(.run == "bash tests/metadata-code-scanning-ruleset.sh")]
    | length == 1 and (.[0] | has("if") | not)
      and (.[0] | has("continue-on-error") | not)' <<< "$steps" >/dev/null || { fail 'missing unconditional CI guard'; return 1; }
}
kubectl kustomize "$root/deploy" > "$work/render.yaml" || { fail 'render failed'; exit 1; }
check_rule "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
# Exercise the rendered policy, not a second synthetic resource.
mutations=(
  'del(.spec.managementPolicies)'
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies = ["Observe"]'
  '.spec.managementPolicies = ["Observe","Create","LateInitialize"]'
  '.spec.forProvider.name = "another-rule"'
  '.spec.forProvider.target = "tag"'
  '.spec.forProvider.enforcement = "disabled"'
  '.spec.forProvider.bypassActors = [{"actorId":0,"actorType":"OrganizationAdmin","bypassMode":"always"}]'
  '.spec.forProvider.conditions[0].repositoryName[0].include = ["~ALL"]'
  '.spec.forProvider.conditions[0].repositoryName[0].include = [".github"]'
  '.spec.forProvider.conditions[0].repositoryName[0].exclude = ["monorepo"]'
  '.spec.forProvider.conditions[0].repositoryProperty = [{"name":"Type","propertyValues":["Metadata"],"source":"custom"}]'
  '.spec.forProvider.conditions[0].refName[0].include = ["refs/heads/control"]'
  '.spec.forProvider.conditions[0].refName[0].exclude = ["~DEFAULT_BRANCH"]'
  '.spec.forProvider.rules = []'
  '.spec.forProvider.rules[0].requiredCodeScanning[0].requiredCodeScanningTool[0].tool = "another-scanner"'
  '.spec.forProvider.rules[0].requiredCodeScanning[0].requiredCodeScanningTool[0].alertsThreshold = "errors"'
  '.spec.forProvider.rules[0].requiredCodeScanning[0].requiredCodeScanningTool[0].securityAlertsThreshold = "high_or_higher"'
  '.metadata.annotations."crossplane.io/external-name" = "6455804"'
  '.apiVersion = "repo.github.m.upbound.io/v1alpha1"'
  '.spec.providerConfigRef.name = "another-provider"'
)
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-metadata-code-scanning-results")'
for mutation in "${mutations[@]}"; do
  yq "($selector) |= ($mutation)" "$work/render.yaml" > "$work/bad.yaml"
  if check_rule "$work/bad.yaml" > "$work/diagnostic" 2>&1; then fail "accepted mutation $mutation"; exit 1; fi
  grep -qF 'unexpected CodeQL policy' "$work/diagnostic"
done
# Plausible output followed by reader failure must not satisfy a conditional call.
mkdir "$work/bin"
real_yq="$(command -v yq)"
cat > "$work/bin/yq" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_YQ" "$@"
exit 42
WRAPPER
chmod +x "$work/bin/yq"
if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" check_rule "$work/render.yaml" > "$work/diagnostic" 2>&1; then fail 'accepted failed reader'; exit 1; fi
grep -qF 'unreadable render' "$work/diagnostic"
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/metadata-code-scanning-ruleset.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/metadata-code-scanning-ruleset.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/metadata-code-scanning-ruleset.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" > "$work/ci.yaml"
  if check_ci "$work/ci.yaml" > "$work/diagnostic" 2>&1; then fail 'accepted weakened CI guard'; exit 1; fi
  grep -qF 'missing unconditional CI guard' "$work/diagnostic"
done
printf 'metadata-code-scanning-ruleset: PASS; exact organization scope, all findings, no bypass and 25 rejection controls\n'
