#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "${render}"' EXIT

fail() {
  echo "platform-merge-queue-ruleset test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null || fail "required tool '${tool}' not found"
done

kubectl kustomize "${repo_root}/deploy" >"${render}" ||
  fail "kubectl kustomize deploy/ failed"

selector='select(.kind == "RepositoryRuleset" and .metadata.name == "platform-require-merge-queue")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered platform merge-queue ruleset, got ${count}"

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

# The imported production gate: its id is the live ruleset, never a new one.
assert_value "external-name" "5275020" '.metadata.annotations."crossplane.io/external-name"'
assert_value "repository" "platform" '.spec.forProvider.repository'
assert_value "target" "branch" '.spec.forProvider.target'
assert_value "enforcement" "active" '.spec.forProvider.enforcement'
# Observe + Update only: Create would never be needed for an imported ruleset, Delete would let
# removing this file delete the production merge gate, and LateInitialize would copy observed
# values over the declared timeout.
assert_json "management policy" '["Observe","Update"]' '.spec.managementPolicies'

# Update applies exactly what is declared, so every observed part of the ruleset must be here.
# Dropping the bypass actor would silently remove the admin bypass on the production gate.
assert_json "bypass actors" '[{"actorType":"OrganizationAdmin","bypassMode":"always"}]' '.spec.forProvider.bypassActors'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "excluded branches" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
assert_json "merge queue" '[{"checkResponseTimeoutMinutes":120,"groupingStrategy":"ALLGREEN","maxEntriesToBuild":1,"maxEntriesToMerge":1,"mergeMethod":"SQUASH","minEntriesToMerge":1,"minEntriesToMergeWaitMinutes":5}]' '.spec.forProvider.rules[0].mergeQueue'

# The platform#3097 probe has served its purpose and must not come back.
probe="$(yq -N 'select(.kind == "RepositoryRuleset" and .metadata.name == "platform-template-probe-bypass-roundtrip") | .metadata.name' "${render}" | grep -c . || true)"
[[ "${probe}" == "0" ]] || fail "the disposable bypass round-trip probe is still rendered"

echo "platform-merge-queue-ruleset: OK"
