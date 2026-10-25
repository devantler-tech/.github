#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
inventory_work="$(mktemp -d)"
trap 'rm -f "${render}"; rm -rf "${inventory_work}"' EXIT

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
assert_value "ruleset enforcement" "disabled" '.spec.forProvider.enforcement'
assert_json "management policy" '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json "target repository" '[1303188705]' '.spec.forProvider.conditions[0].repositoryId'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "target exclusions" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "bypass actor count" "0" '(.spec.forProvider.bypassActors // []) | length'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
# Native overlap passed before this retirement. The shared injection and the
# executed-result binding are independently asserted by repository-admission-ruleset.sh.
assert_json "inert retired rule" '[{"creation":false,"deletion":false,"nonFastForward":false,"requiredLinearHistory":false,"requiredSignatures":false,"update":false}]' '.spec.forProvider.rules'

inventory="${repo_root}/deploy/organization-rulesets/README.md"
grep -Fq 'The 15 imported org rulesets' "${inventory}" ||
  fail "organization ruleset inventory must account for 15 imported rulesets"
# Lifecycle authority, not an active/retired display label, determines ownership.
# Compare the exact roster so equal counts cannot hide a missing or replaced row.
# Compare the documented managed-policy roster in $1 with every Create-managed
# policy in the complete render. Empty, duplicate or mismatched rosters fail.
managed_inventory_valid() {
  # shellcheck disable=SC2016
  awk -F'|' '$2 ~ /^ `[a-z-]+\.yaml` $/ && $4 ~ /^ Managed \(Create\)/ {
    gsub(/[ `]/, "", $2); sub(/\.yaml$/, "", $2); print $2
  }' "$1" | sort >"$inventory_work/documented" || return 1
  yq -N 'select(.kind == "OrganizationRuleset" and (.spec.managementPolicies | contains(["Create"]))) | .metadata.name' "$render" |
    sort >"$inventory_work/rendered" || return 1
  [[ -s "$inventory_work/documented" && -s "$inventory_work/rendered" ]] || return 1
  cmp -s "$inventory_work/documented" "$inventory_work/rendered"
}
managed_inventory_valid "$inventory" || fail 'documented managed roster differs from the complete render'
for control in missing replaced duplicate extra; do
  case "$control" in
  missing)
    awk 'index($0, "`require-world-at-ruin-trusted-regressions.yaml`")==0' "$inventory" >"$inventory_work/broken.md"
    ;;
  replaced)
    sed 's/require-world-at-ruin-trusted-regressions.yaml/unknown-managed-policy.yaml/' "$inventory" >"$inventory_work/broken.md"
    ;;
  duplicate)
    awk '{print; if(index($0, "`require-world-at-ruin-trusted-regressions.yaml`")) print}' "$inventory" >"$inventory_work/broken.md"
    ;;
  extra)
    cp "$inventory" "$inventory_work/broken.md"
    printf "| \`unknown-managed-policy.yaml\` | Extra | Managed (Create) |\n" >>"$inventory_work/broken.md"
    ;;
  esac
  if managed_inventory_valid "$inventory_work/broken.md"; then fail "accepted $control managed inventory"; fi
done
# Schema inspection is not a live census. Keep rendered ownership checks above,
# and require the capability inventory to preserve that evidence boundary.
if ! grep -Fq 'Schema support determines what can be declared; it does not prove adoption,' "${inventory}" ||
  ! grep -Fq 'There is no current ruleset census in this schema inspection.' "${inventory}"; then
  fail "provider capability inventory must distinguish reviewed schema from live adoption and census evidence"
fi

echo "world-at-ruin-regression-ruleset: OK"
