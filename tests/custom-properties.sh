#!/usr/bin/env bash
# Rendered repository-property coverage and lifecycle safety (.github#773).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
kubectl kustomize "$root/deploy" >"$work/render.yaml"
yq -N -o=json -I=0 '.' "$work/render.yaml" >"$work/render.jsonl"
jq -se '
  [.[] | select(.kind == "Repository" and .spec.forProvider.archived != true) | .spec.forProvider.name] as $repos |
  [.[] | select(.kind == "RepositoryCustomProperty")] as $props |
  ["Type", "EnableAutoMerge", "ScanGitHubActions", "AutomaticallyRequestCopilotCodeReview"] as $names |
  ($repos | length) >= 10 and
  ($props | length) == (($repos | length) * ($names | length)) and
  ([$props[] | [.spec.forProvider.repository, .spec.forProvider.propertyName]] | unique | length) == ($props | length) and
  all($repos[]; . as $repo | all($names[]; . as $name |
    any($props[]; .spec.forProvider.repository == $repo and .spec.forProvider.propertyName == $name))) and
  all($props[];
    .apiVersion == "repo.github.m.upbound.io/v1alpha1" and
    (.spec.managementPolicies | sort) == ["Create", "Observe", "Update"] and
    .spec.providerConfigRef == {kind:"ProviderConfig",name:"default"} and
    (.metadata.annotations["crossplane.io/external-name"] // "") == "" and
    (.spec.initProvider // {}) == {} and
    (.spec.forProvider.propertyValue | length) == 1 and
    (if .spec.forProvider.propertyName == "Type" then
      .spec.forProvider.propertyType == "single_select" and
      (.spec.forProvider.propertyValue[0] as $value |
        ["Application","Infrastructure","Library","Marketplace","Metadata","Documentation"] | index($value) != null)
    elif .spec.forProvider.propertyName == "AutomaticallyRequestCopilotCodeReview" then
      .spec.forProvider.propertyType == "true_false" and .spec.forProvider.propertyValue == ["false"]
    else
      .spec.forProvider.propertyType == "true_false" and
      (.spec.forProvider.propertyValue[0] == "true" or .spec.forProvider.propertyValue[0] == "false")
    end))
' "$work/render.jsonl" >/dev/null || {
  echo 'FAIL: every managed repository needs four explicit non-deleting assignments with automatic Copilot review disabled' >&2
  exit 1
}
# The catalogue and shell renderer live outside this Go module's cache boundary.
go -C "$root/scripts/custom-properties" test -count=1 ./...
go -C "$root/scripts/custom-properties" run . --root "$root" --check
yq -o=json '.' "$root/.github/workflows/apply-custom-properties.yaml" >"$work/workflow.json"
jq -e '
  .permissions == {} and (.on | keys | sort) == ["push","schedule","workflow_dispatch"] and
  .on.push.branches == ["main"] and
  .jobs.apply.permissions == {contents:"read"} and
  (.jobs.apply.if | contains("github.ref == '\''refs/heads/main'\''")) and
  ([.jobs.apply.steps[] | select(.uses? | strings | startswith("actions/checkout@"))] |
    length == 1 and .[0].with.ref == "${{ github.workflow_sha }}" and .[0].with."persist-credentials" == false) and
  ([.jobs.apply.steps[] | select(.id? == "token")] | length == 1 and
    .[0].with."permission-organization-administration" == "write" and
    .[0].with."permission-organization-custom-properties" == "admin" and
    .[0].with.repositories == ".github") and
  ([.jobs.apply.steps[] | select(.id? == "readback-token")] | length == 1 and
    (.[0].with | keys | sort) == ["client-id","owner","permission-organization-custom-properties","private-key","repositories"] and
    .[0].with.owner == "devantler-tech" and
    .[0].with."permission-organization-custom-properties" == "read" and
    .[0].with.repositories == "${{ steps.readback-repositories.outputs.repositories }}") and
  ([.jobs.apply.steps[] | select(.run? | strings | endswith("--apply-schema"))] | length == 1 and
    .[0].env.GH_PROPERTY_READBACK_TOKEN == "${{ steps.readback-token.outputs.token }}") and
  ([.jobs.apply.steps | to_entries[] | select(.value.run? | strings | endswith("--check")) | .key][0] <
    [.jobs.apply.steps | to_entries[] | select(.value.id? == "token") | .key][0]) and
  ([.jobs.apply.steps | to_entries[] | select(.value.run? | strings | endswith("--check")) | .key][0] <
    [.jobs.apply.steps | to_entries[] | select(.value.id? == "readback-token") | .key][0])
' "$work/workflow.json" >/dev/null
# Exercise the token's repository selector on a distinct complete catalogue.
mkdir -p "$work/selection/custom-properties"
printf '%s\n' '{"repositories":{"public-app":{},"private-intake":{}}}' >"$work/selection/custom-properties/catalogue.json"
jq -r '.jobs.apply.steps[] | select(.id? == "readback-repositories") | .run' "$work/workflow.json" >"$work/selection/run.sh"
(cd "$work/selection" && GITHUB_OUTPUT="$work/selected-repositories" bash run.sh)
test "$(cat "$work/selected-repositories")" = 'repositories=private-intake,public-app'
echo 'PASS: rendered property coverage, native generator and schema refusal controls'
