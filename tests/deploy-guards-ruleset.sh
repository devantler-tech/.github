#!/usr/bin/env bash

set -euo pipefail

# Pins the trusted enforcement of the deploy/ guards (#183): an organization
# ruleset requires .github/workflows/deploy-guards.yaml from this repository's
# reviewed main, and that workflow runs the validators from the ruleset-selected
# source revision, never from the candidate checkout it judges.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${DEPLOY_GUARDS_WORKFLOW:-${repo_root}/.github/workflows/deploy-guards.yaml}"
render="$(mktemp)"
trap 'rm -f "${render}"' EXIT

fail() {
  echo "deploy-guards-ruleset test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null || fail "required tool '${tool}' not found"
done

kubectl kustomize "${repo_root}/deploy" >"${render}" ||
  fail "kubectl kustomize deploy/ failed"

selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-dotgithub-deploy-guards")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered deploy-guards ruleset, got ${count}"

assert_value() {
  local label="$1" expected="$2" expression="$3" actual
  actual="$(yq -r "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_json() {
  local label="$1" expected="$2" expression="$3" actual
  actual="$(yq -o=json -I=0 "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

# 933213756 is devantler-tech/.github: the rule targets only this repository
# and takes its workflow from this repository's reviewed main.
assert_value "ruleset name" "Require workflow - .github deploy guards" '.spec.forProvider.name'
assert_value "ruleset target" "branch" '.spec.forProvider.target'
assert_value "ruleset enforcement" "active" '.spec.forProvider.enforcement'
assert_json "management policy" '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json "target repository" '[933213756]' '.spec.forProvider.conditions[0].repositoryId'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "target exclusions" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "bypass actor count" "0" '(.spec.forProvider.bypassActors // []) | length'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
assert_value "required workflow count" "1" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow | length'
assert_value "source repository" "933213756" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId'
assert_value "source path" ".github/workflows/deploy-guards.yaml" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path'
assert_value "source ref" "refs/heads/main" '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref'

[[ -f "${workflow}" ]] || fail "required workflow ${workflow#"${repo_root}"/} does not exist"

wf() { yq -r "$1" "${workflow}"; }

[[ "$(wf '.on | has("pull_request")')" == "true" ]] || fail "workflow must run on pull_request"
[[ "$(wf '.on | has("merge_group")')" == "true" ]] || fail "workflow must run on merge_group"
[[ "$(wf '.permissions | tojson')" == "{}" ]] || fail "workflow-level permissions must be {}"

# The validators must come from the ruleset-selected source revision. A
# candidate cannot change github.workflow_sha, so this checkout is the trusted one.
# shellcheck disable=SC2016
trusted_checkouts="$(wf '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with.repository == "devantler-tech/.github" and .with.ref == "${{ github.workflow_sha }}" and .with.path == "trusted")] | length')"
[[ "${trusted_checkouts}" == "1" ]] || fail "expected one checkout of the workflow source revision into trusted/, got ${trusted_checkouts}"

unsafe_checkouts="$(wf '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with["persist-credentials"] != false)] | length')"
[[ "${unsafe_checkouts}" == "0" ]] || fail "every checkout must set persist-credentials: false (${unsafe_checkouts} do not)"

for validator in validate-release-contract.sh validate-deploy-deletions.sh; do
  runs="$(wf "[.jobs[].steps[] | select(.run // \"\" | contains(\"${validator}\"))] | length")"
  [[ "${runs}" == "1" ]] || fail "expected exactly one step running ${validator}, got ${runs}"
  trusted="$(wf "[.jobs[].steps[] | select(.run // \"\" | contains(\"trusted/scripts/${validator}\"))] | length")"
  [[ "${trusted}" == "1" ]] || fail "${validator} must run from trusted/scripts, not the candidate checkout"
done

candidate_scripts="$(wf '[.jobs[].steps[] | select(.run // "" | test("(^|[^/[:alnum:]_])(candidate/)?scripts/"))] | length')"
[[ "${candidate_scripts}" == "0" ]] || fail "no step may run a script outside trusted/ (${candidate_scripts} do)"

echo "deploy-guards-ruleset: OK"
