#!/usr/bin/env bash
# Pins the organization ruleset that requires the GitHub token broker policy check
# (#1001, devantler-tech/monorepo ADR 0020): every repository's default branch, no
# repository opt-out, only the organization admin bypass, the check from this
# repository's main branch, and a non-deleting lifecycle.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'github-broker-policies-ruleset: %s\n' "$*" >&2; return 1; }
expected="$(jq -cn '{
  managementPolicies: ["Observe", "Create", "Update", "LateInitialize"],
  forProvider: {
    name: "Require workflow - GitHub token broker policies", target: "branch", enforcement: "active",
    bypassActors: [{actorType: "OrganizationAdmin", bypassMode: "always"}],
    conditions: [{
      refName: [{include: ["~DEFAULT_BRANCH"], exclude: []}],
      repositoryName: [{include: ["~ALL"], exclude: [], protected: false}]
    }],
    rules: [{requiredWorkflows: [{doNotEnforceOnCreate: true, requiredWorkflow: [{
      repositoryId: 933213756, path: ".github/workflows/check-github-broker-policies.yaml", ref: "refs/heads/main"
    }]}]}]
  },
  providerConfigRef: {kind: "ProviderConfig", name: "default"}
}')"
check_rules() {
  local observed
  observed="$(yq -o=json -I=0 '.' "$1" | jq -s '[.[] | select(.kind == "OrganizationRuleset")]')" || { fail 'unreadable render'; return 1; }
  jq -e --argjson expected "$expected" '
    [.[] | select(.metadata.name == "require-github-broker-policies")]
    | length == 1
      and .[0].apiVersion == "enterprise.github.m.upbound.io/v1alpha1"
      and .[0].spec == $expected
      and ((.[0].metadata.annotations // {}) | has("crossplane.io/external-name") | not)
  ' <<<"$observed" >/dev/null || { fail 'unexpected broker policy ruleset'; return 1; }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || { fail 'unreadable CI'; return 1; }
  jq -e '[.[] | select(.run == "bash tests/github-broker-policies-ruleset.sh")]
    | length == 1 and (.[0] | has("if") | not) and (.[0] | has("continue-on-error") | not)' <<<"$steps" >/dev/null ||
    { fail 'missing unconditional CI guard'; return 1; }
}
kubectl kustomize "$root/deploy" >"$work/render.yaml" || { fail 'render failed'; exit 1; }
check_rules "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
[[ -f "$root/.github/workflows/check-github-broker-policies.yaml" ]] || { fail 'the required workflow is missing'; exit 1; }

# Every way the ruleset could stop covering a repository, or cover it less, fails.
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-github-broker-policies")'
mutations=(
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies = ["Observe"]'
  '.spec.forProvider.enforcement = "evaluate"'
  '.spec.forProvider.enforcement = "disabled"'
  '.spec.forProvider.target = "tag"'
  '.spec.forProvider.bypassActors += [{"actorType":"Integration","actorId":1025824,"bypassMode":"always"}]'
  '.spec.forProvider.bypassActors += [{"actorType":"RepositoryRole","actorId":5,"bypassMode":"always"}]'
  '.spec.forProvider.bypassActors[0].bypassMode = "pull_request"'
  '.spec.forProvider.conditions[0].repositoryName[0].exclude = ["platform"]'
  '.spec.forProvider.conditions[0].repositoryName[0].include = ["platform"]'
  '.spec.forProvider.conditions[0].repositoryName = []'
  '.spec.forProvider.conditions[0].refName[0].include = ["refs/heads/main"]'
  '.spec.forProvider.conditions[0].refName[0].exclude = ["~DEFAULT_BRANCH"]'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path = ".github/workflows/other.yaml"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref = "refs/heads/other"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId = 786274843'
  '.spec.forProvider.rules[0].requiredWorkflows[0].doNotEnforceOnCreate = false'
  'del(.spec.forProvider.rules[0].requiredWorkflows)'
  '.metadata.annotations."crossplane.io/external-name" = "1"'
  '.spec.providerConfigRef.name = "another-provider"'
)
for change in "${mutations[@]}"; do
  yq "(${selector}) |= (${change})" "$work/render.yaml" >"$work/bad.yaml"
  if check_rules "$work/bad.yaml" >"$work/diagnostic" 2>&1; then fail "accepted mutation ${change}"; exit 1; fi
  grep -qF 'unexpected broker policy ruleset' "$work/diagnostic"
done
# A duplicate would leave two identities managing one policy.
{ cat "$work/render.yaml"; printf -- '---\n'; yq "${selector}" "$work/render.yaml"; } >"$work/bad.yaml"
if check_rules "$work/bad.yaml" >"$work/diagnostic" 2>&1; then fail 'accepted a duplicate ruleset'; exit 1; fi
printf 'github-broker-policies-ruleset: %d mutations refused\n' "${#mutations[@]}"
