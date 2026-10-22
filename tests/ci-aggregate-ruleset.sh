#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT
fail() { echo "ci-aggregate-ruleset test: $*" >&2; exit 1; }
kubectl kustomize "$root/deploy" >"$render"
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-monorepo-ci-aggregate-contract")'
count="$(yq -N "$selector | .metadata.name" "$render" | grep -c . || true)"
[[ "$count" == 1 ]] || fail "expected one retained CI aggregate ruleset"
assert_json() {
  local expected="$1" expression="$2" actual
  actual="$(yq -o=json -I=0 "$selector | $expression" "$render")"
  [[ "$actual" == "$expected" ]] || fail "$expression: expected $expected, got $actual"
}
assert_json '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json '"branch"' '.spec.forProvider.target'
assert_json '"disabled"' '.spec.forProvider.enforcement'
assert_json '[786274843]' '.spec.forProvider.conditions[0].repositoryId'
assert_json '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_json '[]' '(.spec.forProvider.bypassActors // [])'
# Shared admission and its independently required product result replace this
# singleton. Keep its identity and lifecycle, but no executable association.
# repository-admission-ruleset.sh rejects loss of the replacement protections,
# reactivation of either singleton, and restoration of a workflow association.
assert_json '[{"creation":false,"deletion":false,"nonFastForward":false,"requiredLinearHistory":false,"requiredSignatures":false,"update":false}]' '.spec.forProvider.rules'
echo "ci-aggregate-ruleset: OK"
