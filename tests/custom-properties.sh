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
  ["Type", "EnableAutoMerge", "ScanGitHubActions"] as $names |
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
        ["Application","Infrastructure","Library","Marketplace","Metadata","Template","Documentation"] | index($value) != null)
    else
      .spec.forProvider.propertyType == "true_false" and
      (.spec.forProvider.propertyValue[0] == "true" or .spec.forProvider.propertyValue[0] == "false")
    end))
' "$work/render.jsonl" >/dev/null || {
  echo 'FAIL: every managed repository needs exactly three explicit non-deleting property assignments' >&2
  exit 1
}
go -C "$root/scripts/custom-properties" test ./...
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
    .[0].with."permission-organization-administration" == "read" and
    .[0].with."permission-organization-custom-properties" == "write" and
    .[0].with.repositories == ".github") and
  ([.jobs.apply.steps | to_entries[] | select(.value.run? | strings | endswith("--check")) | .key][0] <
    [.jobs.apply.steps | to_entries[] | select(.value.id? == "token") | .key][0])
' "$work/workflow.json" >/dev/null
echo 'PASS: rendered property coverage, native generator and schema refusal controls'
