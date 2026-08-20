#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "${render}"' EXIT

fail() {
  echo "world-at-ruin-regression-ruleset test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null || fail "required tool '${tool}' not found"
done

kubectl kustomize "${repo_root}/deploy" >"${render}" ||
  fail "kubectl kustomize deploy/ failed"

selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-world-at-ruin-trusted-regressions")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered trusted-regression ruleset, got ${count}"

assert_value() {
  local label="$1"
  local expected="$2"
  local expression="$3"
  local actual
  actual="$(yq -r "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

assert_json() {
  local label="$1"
  local expected="$2"
  local expression="$3"
  local actual
  actual="$(yq -o=json -I=0 "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

assert_value "ruleset name" "Require workflow - World at Ruin trusted regressions" '.spec.forProvider.name'
assert_value "ruleset target" "branch" '.spec.forProvider.target'
assert_value "ruleset enforcement" "active" '.spec.forProvider.enforcement'
assert_json "management policy" '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json "target repository" '[1303188705]' '.spec.forProvider.conditions[0].repositoryId'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "target exclusions" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "bypass actor count" "0" '(.spec.forProvider.bypassActors // []) | length'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
assert_value "required workflow block count" "1" '.spec.forProvider.rules[0].requiredWorkflows | length'
assert_value "required workflow count" "1" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow | length'
assert_value "source repository" "948529001" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId'
assert_value "source path" ".github/workflows/world-at-ruin-required-regressions.yaml" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path'
assert_value "source ref" "refs/heads/main" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref'

grep -Fq '10 of the 22 org rulesets' "${repo_root}/deploy/organization-rulesets/README.md" ||
  fail "organization ruleset inventory must account for 10 imported, 2 managed, and 10 UI-managed rulesets"

echo "world-at-ruin-regression-ruleset: OK"
