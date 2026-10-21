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
      {"context":".NET template tests (ubuntu-latest)","integrationId":15368},
      {"context":".NET template tests (windows-latest)","integrationId":15368},
      {"context":".NET template tests (macos-latest)","integrationId":15368}
    ],
    "strictRequiredStatusChecksPolicy":false
  }]}] and
  .providerConfigRef == {"kind":"ProviderConfig","name":"default"}
' <<<"$policy" >/dev/null || fail 'provider payload loses a platform, producer binding or branch protection'

# Positive and intentional-failure controls proved every native platform binding.
legacy="$(yq -r 'select(.kind == "OrganizationRuleset" and .metadata.name == "require-dotnet-template-tests") | .spec.forProvider.enforcement' "$render")"
[[ "$legacy" == disabled ]] || fail 'duplicate organization gate must remain retired after native proof'
echo 'dotnet repository validation: all native legs required; duplicate organization gate retired'
