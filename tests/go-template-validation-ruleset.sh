#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT
fail() { echo "go-template-validation-ruleset test: $*" >&2; exit 1; }
kubectl kustomize "$root/deploy" >"$render"
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-go-template-validation")'
count="$(yq -N "$selector | .metadata.name" "$render" | grep -c . || true)"
[[ "$count" == 1 ]] || fail "expected one Go template validation ruleset"
assert_json() {
  local expected="$1" expression="$2" actual
  actual="$(yq -o=json -I=0 "$selector | $expression" "$render")"
  [[ "$actual" == "$expected" ]] || fail "$expression: expected $expected, got $actual"
}
assert_json '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json '"branch"' '.spec.forProvider.target'
assert_json '"active"' '.spec.forProvider.enforcement'
assert_json '[1065308377]' '.spec.forProvider.conditions[0].repositoryId'
assert_json '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_json '[]' '(.spec.forProvider.bypassActors // [])'
assert_json '[{"requiredWorkflows":[{"requiredWorkflow":[{"path":".github/workflows/validate-go-project.yaml","ref":"refs/heads/main","repositoryId":948529001}]}]}]' '.spec.forProvider.rules'
echo "go-template-validation-ruleset: OK"
