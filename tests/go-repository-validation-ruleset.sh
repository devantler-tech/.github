#!/usr/bin/env bash
# Require the native Go aggregate without retiring the temporary organization gate.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT
fail() { echo "go repository validation: $*" >&2; exit 1; }
kubectl kustomize "$root/deploy" >"$render"
selector='select(.kind == "RepositoryRuleset" and .metadata.name == "go-template-require-validation")'
policy="$(yq -o=json -I=0 "$selector | .spec" "$render")"
[[ -n "$policy" ]] || fail 'repository-owned validation is not required'
jq -s -e 'length == 1' <<<"$policy" >/dev/null || fail 'expected exactly one repository policy'
jq -e '
  .managementPolicies == ["Observe", "Create", "Update", "LateInitialize"] and
  .forProvider.repository == "go-template" and
  .forProvider.name == "Require local Go template validation" and
  .forProvider.target == "branch" and
  .forProvider.enforcement == "active" and
  .forProvider.conditions == [{"refName":[{"include":["~DEFAULT_BRANCH"],"exclude":[]}]}] and
  (.forProvider.bypassActors // []) == [] and
  .forProvider.rules == [{"requiredStatusChecks":[{
    "requiredCheck":[{"context":"CI - Required Checks","integrationId":15368}],
    "strictRequiredStatusChecksPolicy":false
  }]}] and
  .providerConfigRef == {"kind":"ProviderConfig","name":"default"}
' <<<"$policy" >/dev/null || fail 'provider payload loses native validation, its producer or branch protection'

legacy="$(yq -r 'select(.kind == "OrganizationRuleset" and .metadata.name == "require-go-template-validation") | .spec.forProvider.enforcement' "$render")"
[[ "$legacy" == active ]] || fail 'legacy protection was retired before native overlap proof'
echo 'go repository validation: native aggregate required; legacy overlap retained'
