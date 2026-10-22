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

# No dormant policy may retain a source association after its wrapper is removed.
# The complete observation test separately pins selectors, bypasses and lifecycle.
# Read one rendered provider payload from stdin. Return success only for the
# disabled, provider-compatible inert rule; missing or duplicate payloads fail.
retired_policy_valid() {
  jq -se 'length == 1 and (.[0] | .enforcement == "disabled" and .rules == [{"creation":false,"deletion":false,"nonFastForward":false,"requiredLinearHistory":false,"requiredSignatures":false,"update":false}])' >/dev/null
}
for name in require-dotnet-template-tests require-workflows-dotnet; do
  legacy="$(NAME="$name" yq -o=json -I=0 'select(.kind == "OrganizationRuleset" and .metadata.name == strenv(NAME)) | .spec.forProvider' "$render")"
  retired_policy_valid <<<"$legacy" || fail "$name must be disabled without an obsolete source association"
  for mutation in '.enforcement="active"' '.rules=[{"requiredWorkflows":[{"requiredWorkflow":[{"path":".github/workflows/run-dotnet-tests.yaml"}]}]}]'; do
    if jq "$mutation" <<<"$legacy" | retired_policy_valid; then
      fail "$name accepted reactivation or a restored source association"
    fi
  done
done
echo 'dotnet repository validation: all native legs required; both old policies inert and disabled'
