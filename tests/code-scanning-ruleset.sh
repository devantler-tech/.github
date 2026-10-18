#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'code-scanning-ruleset: %s\n' "$*" >&2; return 1; }
expected='{"managementPolicies":["Observe"],"forProvider":{"name":"Require code scanning results","target":"branch","enforcement":"active"},"providerConfigRef":{"kind":"ProviderConfig","name":"default"}}'
check_rule() {
  local observed
  observed="$(yq -o=json -I=0 '.' "$1" | jq -s '[.[] | select(.kind == "OrganizationRuleset" and .metadata.name == "require-code-scanning-results")]')" || { fail 'unreadable render'; return 1; }
  jq -e --argjson expected "$expected" '
    length == 1 and .[0].apiVersion == "enterprise.github.m.upbound.io/v1alpha1"
    and .[0].spec == $expected
    and (.[0].metadata.annotations["crossplane.io/external-name"] == "6455804")
  ' <<< "$observed" >/dev/null || { fail 'unexpected CodeQL policy'; return 1; }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || { fail 'unreadable CI'; return 1; }
  jq -e '[.[] | select(.run == "bash tests/code-scanning-ruleset.sh")]
    | length == 1 and (.[0] | has("if") | not)
      and (.[0] | has("continue-on-error") | not)' <<< "$steps" >/dev/null || { fail 'missing unconditional CI guard'; return 1; }
}
kubectl kustomize "$root/deploy" > "$work/render.yaml" || { fail 'render failed'; exit 1; }
check_rule "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
# Exercise the rendered policy, not a second synthetic resource.
mutations=(
  'del(.spec.managementPolicies)'
  '.spec.managementPolicies += ["Update"]'
  '.spec.managementPolicies += ["Create"]'
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies += ["LateInitialize"]'
  '.metadata.annotations."crossplane.io/external-name" = "123"'
  'del(.metadata.annotations."crossplane.io/external-name")'
  '.spec.forProvider.name = "another-rule"'
  '.spec.forProvider.target = "tag"'
  '.spec.forProvider.enforcement = "disabled"'
  '.spec.forProvider.rules = [{"deletion":true}]'
  '.spec.forProvider.conditions = [{"repositoryName":[{"include":["~ALL"],"exclude":[]}]}]'
  '.apiVersion = "repo.github.m.upbound.io/v1alpha1"'
  '.spec.providerConfigRef.name = "another-provider"'
)
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-code-scanning-results")'
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
  'del(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/code-scanning-ruleset.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/code-scanning-ruleset.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/code-scanning-ruleset.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" > "$work/ci.yaml"
  if check_ci "$work/ci.yaml" > "$work/diagnostic" 2>&1; then fail 'accepted weakened CI guard'; exit 1; fi
  grep -qF 'missing unconditional CI guard' "$work/diagnostic"
done
printf 'code-scanning-ruleset: PASS; exact rendered Observe-only import and 18 rejection controls\n'
