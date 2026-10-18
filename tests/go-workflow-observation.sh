#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  printf 'go-workflow-observation: %s\n' "$*" >&2
  return 1
}
expected='{"managementPolicies":["Observe"],"forProvider":{"name":"Require workflows to pass before merging for Go","target":"branch","enforcement":"active"},"providerConfigRef":{"kind":"ProviderConfig","name":"default"}}'
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
# Mutate the real rendered import. No mutation may acquire write authority or
# round-trip an incomplete policy while repository selectors remain unknown.
mutations=(
  'del(.spec.managementPolicies)'
  '.spec.managementPolicies += ["Update"]'
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
  '.spec.forProvider.rules = [{"workflows":[{"workflows":[{"repositoryId":933213756}]}]}]'
  '.spec.forProvider.conditions = [{"repositoryName":[{"include":["~ALL"],"exclude":[]}]}]'
  '.spec.forProvider.bypassActors = []'
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
printf 'go-workflow-observation: PASS; rendered read-only import and 25 rejection controls\n'
