#!/usr/bin/env bash
# Exercise the policy against invalid renderings, including operational failures.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
guard="$repo_root/tests/runner-group-policy.sh"

cat >"$scratch/valid.json" <<'JSON'
{
  "apiVersion":"actions.github.m.upbound.io/v1alpha1",
  "kind":"RunnerGroup",
  "metadata":{"name":"ksail-code-quality"},
  "spec":{
    "managementPolicies":["Observe","Create","Update"],
    "providerConfigRef":{"kind":"ProviderConfig","name":"default"},
    "forProvider":{
      "name":"ksail-code-quality",
      "visibility":"selected",
      "selectedRepositoryIds":[737584922],
      "allowsPublicRepositories":true,
      "restrictedToWorkflows":false,
      "selectedWorkflows":[]
    }
  }
}
JSON
bash "$guard" --rendered "$scratch/valid.json" >/dev/null

assert_failure() {
  local file="$1" expected="$2" reason="$3" result=0
  bash "$guard" --rendered "$file" >"$scratch/output" 2>&1 || result=$?
  if [[ "$result" != "$expected" ]] || ! grep -Fq "$reason" "$scratch/output"; then
    echo "runner-group-policy-blocks: expected status $expected and '$reason', got $result" >&2
    cat "$scratch/output" >&2
    exit 1
  fi
}

mutate() {
  local expression="$1" reason="$2"
  jq "$expression" "$scratch/valid.json" >"$scratch/bad.json"
  assert_failure "$scratch/bad.json" 1 "$reason"
}

mutate '.apiVersion = "actions.github.upbound.io/v1alpha1"' 'new namespaced KSail group'
mutate '.metadata.namespace = "another-tenant"' 'new namespaced KSail group'
mutate '.metadata.name = "Default"' 'new namespaced KSail group'
mutate '.metadata.annotations = {"crossplane.io/external-name":"999"}' 'unverified external identity'
mutate '.spec.managementPolicies += ["Delete"]' 'without deletion'
mutate '.spec.managementPolicies += ["LateInitialize"]' 'without deletion'
mutate '.spec.providerConfigRef.name = "another-app"' 'existing provider'
mutate 'del(.spec.providerConfigRef.kind)' 'existing provider'
mutate '.spec.providerConfigRef.kind = "ClusterProviderConfig"' 'existing provider'
mutate '.spec.initProvider = {"visibility":"all"}' 'existing provider'
mutate '.spec.forProvider.visibility = "all"' 'restricted to KSail alone'
mutate '.spec.forProvider.visibility = "private"' 'restricted to KSail alone'
mutate '.spec.forProvider.selectedRepositoryIds += [1]' 'restricted to KSail alone'
mutate '.spec.forProvider.selectedRepositoryIds = []' 'restricted to KSail alone'
mutate '.spec.forProvider.selectedRepositoryIds = ["737584922"]' 'restricted to KSail alone'
mutate 'del(.spec.forProvider.allowsPublicRepositories)' 'restricted to KSail alone'
mutate '.spec.forProvider.allowsPublicRepositories = false' 'restricted to KSail alone'
mutate '.spec.forProvider.name = "Default"' 'restricted to KSail alone'
mutate 'del(.spec.forProvider.restrictedToWorkflows)' 'restricted to KSail alone'
mutate '.spec.forProvider.restrictedToWorkflows = true' 'restricted to KSail alone'
mutate '.spec.forProvider.selectedWorkflows = ["devantler-tech/ksail/.github/workflows/ci.yaml@refs/heads/main"]' 'restricted to KSail alone'

printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' >"$scratch/no-group.yaml"
assert_failure "$scratch/no-group.yaml" 1 'exactly one RunnerGroup'
cat "$scratch/valid.json" >"$scratch/duplicate.yaml"
printf '\n---\n' >>"$scratch/duplicate.yaml"
cat "$scratch/valid.json" >>"$scratch/duplicate.yaml"
assert_failure "$scratch/duplicate.yaml" 1 'exactly one RunnerGroup'
printf 'bad: [\n' >"$scratch/malformed.yaml"
assert_failure "$scratch/malformed.yaml" 2 'UNKNOWN'
assert_failure "$scratch/missing.yaml" 2 'UNKNOWN'

echo 'runner-group-policy-blocks: 23 policy failures and two UNKNOWN input failures verified'
