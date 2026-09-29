#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "${render}"' EXIT

fail() {
  echo "bypass-roundtrip-probe-ruleset test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null || fail "required tool '${tool}' not found"
done

kubectl kustomize "${repo_root}/deploy" >"${render}" ||
  fail "kubectl kustomize deploy/ failed"

selector='select(.kind == "RepositoryRuleset" and .metadata.name == "platform-template-probe-bypass-roundtrip")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered probe ruleset, got ${count}"

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

# The probe must never enforce anything: it exists only to be observed.
assert_value "enforcement" "disabled" '.spec.forProvider.enforcement'
assert_value "target repository" "platform-template" '.spec.forProvider.repository'
assert_value "target" "branch" '.spec.forProvider.target'
assert_value "external-name" "24193850" '.metadata.annotations."crossplane.io/external-name"'
# Observe + Create + Update mirrors the planned promotion; Delete lets removing the
# file clean the probe up. LateInitialize would copy observed values into spec and
# hide exactly the round-trip this probe measures.
assert_json "management policy" '["Observe","Create","Update","Delete"]' '.spec.managementPolicies'

assert_json "bypass actors" '[{"actorType":"OrganizationAdmin","bypassMode":"always"}]' '.spec.forProvider.bypassActors'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
assert_json "merge queue" '[{"checkResponseTimeoutMinutes":90,"groupingStrategy":"ALLGREEN","maxEntriesToBuild":1,"maxEntriesToMerge":1,"mergeMethod":"SQUASH","minEntriesToMerge":1,"minEntriesToMergeWaitMinutes":5}]' '.spec.forProvider.rules[0].mergeQueue'

# The probe must not be mistaken for the production gate's promotion.
gate='select(.kind == "RepositoryRuleset" and .metadata.name == "platform-require-merge-queue")'
gate_policy="$(yq -o=json -I=0 "${gate} | .spec.managementPolicies" "${render}")"
[[ "${gate_policy}" == '["Observe"]' ]] ||
  fail "platform's merge-queue ruleset must stay Observe-only while the probe runs, got '${gate_policy}'"

echo "bypass-roundtrip-probe-ruleset: OK"
