#!/usr/bin/env bash
# Validate the provider payload that independently requires every local .NET leg.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT
fail() { echo "dotnet repository validation: $*" >&2; exit 1; }
kubectl kustomize "$root/deploy" >"$render"
selector='select(.kind == "RepositoryRuleset" and .metadata.name == "dotnet-template-require-validation")'
policy="$(yq -o=json -I=0 "$selector | .spec" "$render")"
[[ -n "$policy" ]] || fail 'repository-owned validation is not required'
jq -s -e 'length == 1' <<<"$policy" >/dev/null || fail 'expected exactly one repository policy'
jq -e '
  .managementPolicies == ["Observe", "Create", "Update", "LateInitialize"] and
  .forProvider.repository == "dotnet-template" and
  .forProvider.name == "Require local .NET template validation" and
  .forProvider.target == "branch" and
  .forProvider.enforcement == "active" and
  .forProvider.conditions == [{"refName":[{"include":["~DEFAULT_BRANCH"],"exclude":[]}]}] and
  (.forProvider.bypassActors // []) == [] and
  .forProvider.rules == [{"requiredStatusChecks":[{
    "requiredCheck":[
      {"context":"test (ubuntu-latest)","integrationId":15368},
      {"context":"test (windows-latest)","integrationId":15368},
      {"context":"test (macos-latest)","integrationId":15368}
    ],
    "strictRequiredStatusChecksPolicy":false
  }]}] and
  .providerConfigRef == {"kind":"ProviderConfig","name":"default"}
' <<<"$policy" >/dev/null || fail 'provider payload loses a platform, producer binding or branch protection'

# Overlap is deliberate: source deployment is not live enforcement evidence.
legacy="$(yq -r 'select(.kind == "OrganizationRuleset" and .metadata.name == "require-dotnet-template-tests") | .spec.forProvider.enforcement' "$render")"
[[ "$legacy" == active ]] || fail 'legacy protection was retired before native overlap proof'
echo 'dotnet repository validation: all native legs required; legacy overlap retained'
