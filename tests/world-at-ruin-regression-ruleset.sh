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
assert_value "source repository" "933213756" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId'
assert_value "source path" ".github/workflows/world-at-ruin-required-regressions.yaml" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path'
assert_value "source ref" "refs/heads/main" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref'

selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-world-at-ruin-product-regressions")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered product-regression ruleset, got ${count}"

assert_value "product ruleset name" "Require workflow - World at Ruin product regressions" '.spec.forProvider.name'
assert_value "product ruleset target" "branch" '.spec.forProvider.target'
assert_value "product ruleset enforcement" "active" '.spec.forProvider.enforcement'
assert_json "product management policy" '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json "product target repository" '[1303188705]' '.spec.forProvider.conditions[0].repositoryId'
assert_json "product target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "product target exclusions" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "product bypass actor count" "0" '(.spec.forProvider.bypassActors // []) | length'
assert_value "product rule count" "1" '.spec.forProvider.rules | length'
assert_value "product required workflow block count" "1" '.spec.forProvider.rules[0].requiredWorkflows | length'
assert_value "product required workflow count" "1" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow | length'
assert_value "product source repository" "1303188705" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId'
assert_value "product source path" ".github/workflows/trusted-regressions.yaml" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path'
assert_value "product source ref" "refs/heads/main" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref'

inventory="${repo_root}/deploy/organization-rulesets/README.md"
grep -Fq 'The 10 imported org rulesets' "${inventory}" ||
  fail "organization ruleset inventory must account for 10 imported rulesets"
# The backticks are literal Markdown table cell delimiters, not command substitution.
# shellcheck disable=SC2016
managed_rows="$(grep -c '^| `[a-z-]*\.yaml` | .*(net-new) | Managed (Create)' "${inventory}" || true)"
[[ "${managed_rows}" == "6" ]] ||
  fail "organization ruleset inventory must list 6 managed rulesets, got ${managed_rows}"
managed_rendered="$(yq -N 'select(.kind == "OrganizationRuleset" and (.spec.managementPolicies | contains(["Create"]))) | .metadata.name' "${render}" | grep -c . || true)"
[[ "${managed_rendered}" == "6" ]] ||
  fail "expected 6 rendered managed (Create) organization rulesets, got ${managed_rendered}"
# Schema inspection is not a live census. Keep rendered ownership checks above,
# and require the capability inventory to preserve that evidence boundary.
if ! grep -Fq 'Schema support determines what can be declared; it does not prove adoption,' "${inventory}" ||
  ! grep -Fq 'There is no current ruleset census in this schema inspection.' "${inventory}"; then
  fail "provider capability inventory must distinguish reviewed schema from live adoption and census evidence"
fi

echo "world-at-ruin-regression-ruleset: OK"
