#!/usr/bin/env bash
# Rendered repository-property coverage and lifecycle safety (.github#773).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
kubectl kustomize "$root/deploy" >"$work/render.yaml"
yq -N -o=json -I=0 '.' "$work/render.yaml" >"$work/render.jsonl"
# A repository renamed in place declares its new name first; its property values keep the old
# name until the rename is read back, then move with its other dependents (#956). Map each new
# name to the old one while that is in progress, and leave this empty otherwise.
renaming='{}'
jq -se --argjson renaming "$renaming" '
  [.[] | select(.kind == "Repository" and .spec.forProvider.archived != true) | .spec.forProvider.name | ($renaming[.] // .)] as $repos |
  [.[] | select(.kind == "RepositoryCustomProperty")] as $props |
  ["Type", "EnableAutoMerge", "ScanGitHubActions", "AlwaysValidateGoProject"] as $names |
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
    else
      .spec.forProvider.propertyType == "true_false" and
      (.spec.forProvider.propertyValue[0] == "true" or .spec.forProvider.propertyValue[0] == "false")
    end))
' "$work/render.jsonl" >/dev/null || {
  echo 'FAIL: every managed repository needs exactly four explicit non-deleting assignments and no retired property' >&2
  exit 1
}
# The catalogue and shell renderer live outside this Go module's cache boundary.
go -C "$root/scripts/custom-properties" test -count=1 ./...
go -C "$root/scripts/custom-properties" run . --root "$root" --check
yq -o=json '.' "$root/.github/workflows/apply-custom-properties.yaml" >"$work/workflow.json"
jq -e '
  .permissions == {} and (.on | keys | sort) == ["push","schedule","workflow_dispatch"] and
  .on.push.branches == ["main"] and
  .jobs.apply.permissions == {contents:"read","id-token":"write"} and
  (.jobs.apply.if | contains("github.ref == '\''refs/heads/main'\''")) and
  ([.jobs.apply.steps[] | select(.uses? | strings | startswith("actions/checkout@"))] |
    length == 1 and .[0].with.ref == "${{ github.workflow_sha }}" and .[0].with."persist-credentials" == false) and
  # Both tokens come from the GitHub token broker; their authority is pinned in
  # the two trust policies checked below, never by an App key here.
  ([.jobs.apply.steps[] | select(((.uses? // "") | test("create-github-app-token")) or ((.with? // {}) | has("private-key")))] | length == 0) and
  ([.jobs.apply.steps[] | select(.id? == "token")] | length == 1 and
    (.[0].uses | test("^octo-sts/action@[0-9a-f]{40}$")) and
    .[0].with == {domain:"sts.platform.devantler.tech", scope:"devantler-tech", identity:"apply-custom-properties"}) and
  ([.jobs.apply.steps[] | select(.id? == "readback-token")] | length == 1 and
    (.[0].uses | test("^octo-sts/action@[0-9a-f]{40}$")) and
    .[0].with == {domain:"sts.platform.devantler.tech", scope:"devantler-tech", identity:"apply-custom-properties-readback"}) and
  ([.jobs.apply.steps[] | select(.run? | strings | endswith("--apply-schema"))] | length == 1 and
    .[0].env.GH_PROPERTY_READBACK_TOKEN == "${{ steps.readback-token.outputs.token }}") and
  ([.jobs.apply.steps | to_entries[] | select(.value.run? | strings | endswith("--check")) | .key][0] <
    [.jobs.apply.steps | to_entries[] | select(.value.id? == "token") | .key][0]) and
  ([.jobs.apply.steps | to_entries[] | select(.value.run? | strings | endswith("--check")) | .key][0] <
    [.jobs.apply.steps | to_entries[] | select(.value.id? == "readback-token") | .key][0])
' "$work/workflow.json" >/dev/null
# The write token: organization administration write and custom properties admin,
# scoped to this repository, to exactly this workflow on main, naming no App.
# The read-back token: custom property values and metadata read, organization-wide.
policy_claims='{repository_owner_id:"178524219", job_workflow_ref:"devantler-tech/\\.github/\\.github/workflows/apply-custom-properties\\.yaml@refs/heads/main"}'
yq -o=json '.' "$root/.github/chainguard/apply-custom-properties.sts.yaml" | jq -e "
  . == {issuer:\"https://token.actions.githubusercontent.com\", subject:\"repo:devantler-tech/.github:ref:refs/heads/main\",
    claim_pattern:${policy_claims}, repositories:[\".github\"],
    permissions:{organization_administration:\"write\", organization_custom_properties:\"admin\"}}
" >/dev/null || { echo 'FAIL: the property write policy must grant only its reviewed authority' >&2; exit 1; }
yq -o=json '.' "$root/.github/chainguard/apply-custom-properties-readback.sts.yaml" | jq -e "
  . == {issuer:\"https://token.actions.githubusercontent.com\", subject:\"repo:devantler-tech/.github:ref:refs/heads/main\",
    claim_pattern:${policy_claims},
    permissions:{metadata:\"read\", organization_custom_properties:\"read\"}}
" >/dev/null || { echo 'FAIL: the property read-back policy must grant only read authority' >&2; exit 1; }
echo 'PASS: rendered property coverage, native generator and schema refusal controls'
