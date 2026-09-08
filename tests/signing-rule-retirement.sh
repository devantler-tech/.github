#!/usr/bin/env bash
# Retain the approved disabled record without broadening its scope or lifecycle.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT
fail() { echo "signing-rule-retirement test: $*" >&2; exit 1; }

kubectl kustomize "$root/deploy" >"$render"
selector='select(.apiVersion == "enterprise.github.m.upbound.io/v1alpha1" and .kind == "OrganizationRuleset" and .metadata.name == "require-signed-commits")'
count="$(yq -N "$selector | .metadata.name" "$render" | grep -c . || true)"
[[ "$count" == 1 ]] || fail "the existing signing ruleset must remain in the render"

assert_json() {
  local expected="$1" expression="$2" actual
  actual="$(yq -o=json -I=0 "$selector | $expression" "$render")"
  [[ "$actual" == "$expected" ]] || fail "$expression: expected $expected, got $actual"
}

# Only this existing object may be updated. Prune or external disappearance must
# never authorize deletion or recreation, and late initialization stays disabled.
assert_json '"5397812"' '.metadata.annotations."crossplane.io/external-name"'
assert_json '["Observe","Update"]' '.spec.managementPolicies'
assert_json '{"kind":"ProviderConfig","name":"default"}' '.spec.providerConfigRef'
assert_json '{}' '(.spec.initProvider // {})'
assert_json '"disabled"' '.spec.forProvider.enforcement'
assert_json '"Require signed commits"' '.spec.forProvider.name'
assert_json '"branch"' '.spec.forProvider.target'

# Update sends the full ruleset: preserve the observed selectors, empty bypass
# list and all rule booleans explicitly. Empty ref coverage must stay empty.
assert_json '[]' '.spec.forProvider.bypassActors'
assert_json '[{"refName":[{"exclude":[],"include":[]}],"repositoryName":[{"exclude":[],"include":["~ALL"],"protected":false}]}]' '.spec.forProvider.conditions | sort_keys(..)'
assert_json '[{"creation":false,"deletion":false,"nonFastForward":false,"requiredLinearHistory":false,"requiredSignatures":true,"update":false}]' '.spec.forProvider.rules | sort_keys(..)'
assert_json '["bypassActors","conditions","enforcement","name","rules","target"]' '.spec.forProvider | keys | sort'

echo "signing-rule-retirement: OK"
