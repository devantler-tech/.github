#!/usr/bin/env bash
# Exercise the actual selector contract and complete current workflow inventory.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ci="$root/.github/workflows/ci.yaml"
yq -o=json . "$ci" > "$work/workflow.json"
jq -e '
  .jobs["select-ci-tests"] as $s |
  ($s.if == "${{ github.event_name != '\''merge_group'\'' && !startsWith(github.event.head_commit.message, '\''chore(main): release '\'') }}") and
  ($s.needs == "catalogue-scope") and
  ($s | has("continue-on-error") | not) and
  ($s.permissions == {"contents":"read"}) and
  ($s.outputs.selected == "${{ steps.select.outputs.selected }}") and
  ([$s.steps[] | select((.uses // "") | startswith("actions/checkout@")) | .with] == [{"fetch-depth":0,"persist-credentials":false}]) and
  ([$s.steps[] | select(.id == "select") | .env.GOWORK] == ["off"]) and
  ([$s.steps[] | select(.id == "select") | .env.GOFLAGS] == [""]) and
  ([$s.steps[] | select(.id == "select") | .env.GOTOOLCHAIN] == ["local"]) and
  ([$s.steps[] | select(.id == "select") | .env.CATALOGUE_SCOPE] == ["${{ needs.catalogue-scope.outputs.catalogue }}"]) and
  (.jobs["ci-required-checks"].needs | index("select-ci-tests") != null)
' "$work/workflow.json" > /dev/null
go -C "$root/.github/scripts/ci-selection" test -race -count=3 ./...
go -C "$root/.github/scripts/ci-selection" vet ./...
touch "$work/output"
EVENT_NAME=push RUN_CATALOGUE=true CATALOGUE_SCOPE=true GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
selected="$(sed -n 's/^selected=//p' "$work/output")"
[[ "$(jq 'length' <<< "$selected")" == 89 ]]
EVENT_NAME=merge_group RUN_CATALOGUE=false GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
[[ "$(tail -n 1 "$work/output")" == 'selected=[]' ]]
# Independently verify all direct local action callers have their exact owner.
jq -e --slurpfile inventory "$root/.github/scripts/ci-selection/inventory.json" '
  all(.jobs | to_entries[] | select(.key | startswith("test-"));
    .key as $id | all(.value.steps[]? | .uses? // empty | select(startswith("./actions/"));
      (.[2:] + "/") as $owner | $inventory[0].jobs[$id] | index($owner) != null))
' "$work/workflow.json" > /dev/null
echo 'PASS: complete job inventory, owner coverage and preserved scheduling'
