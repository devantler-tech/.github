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
[[ "$(jq 'length' <<< "$selected")" == 82 ]]
# Hosted CI reports these callers as skipped because their callee jobs are
# intentionally excluded (dry-run, repository exclusion, or dependency-bot
# suppression). They still exercise interfaces and retain original admission;
# selection must not promise an executed test where no job can run.
interface_callers='["test-apply-signed-fixes-suppresses-bots","test-publish-dotnet-library","test-sync-cluster-policies","test-template-sync","test-template-sync-merge-ignore","test-update-agent-skills","test-update-agent-skills-per-skill","test-validate-go-project-interface"]'
needs="$(jq -cn --argjson skipped "$interface_callers" --slurpfile workflow "$work/workflow.json" '
  reduce ($workflow[0].jobs | keys[]) as $id ({};
    .[$id] = {result: (if ($skipped | index($id)) != null then "skipped" else "success" end)})
')"
reducer="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .run' "$ci")"
JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" bash -c "$reducer" || {
  echo "FAIL: intentional interface-only caller skips incorrectly failed hosted selection" >&2
  exit 1
}
# Main's push event also intentionally excludes these two reusable callees.
# Reproduce that hosted result map through the production selector and reducer.
pr_only_callers='["test-dependency-review-workflow","test-apply-signed-fixes-verifies-without-a-patch"]'
main_needs="$(jq --argjson skipped "$pr_only_callers" 'reduce $skipped[] as $id (.; .[$id].result="skipped")' <<< "$needs")"
JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$main_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$main_needs" bash -c "$reducer" || {
  echo "FAIL: intentional PR-only caller skips incorrectly failed main selection" >&2
  exit 1
}
# A failed preserved call must still fail the global reducer. Expected callee
# exclusions may skip; every selected execution remains mandatory.
for caller in $(jq -nr --argjson interface "$interface_callers" --argjson pr_only "$pr_only_callers" '$interface + $pr_only | .[]'); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="failure"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" bash -c "$reducer" > /dev/null 2>&1; then
    echo "FAIL: failed preserved caller $caller was silently accepted" >&2
    exit 1
  fi
done
for caller in $(jq -r '.[]' <<< "$selected"); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="skipped"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" bash -c "$reducer" > /dev/null 2>&1; then
    echo "FAIL: selected execution $caller was silently skipped" >&2
    exit 1
  fi
done
EVENT_NAME=merge_group RUN_CATALOGUE=false GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
[[ "$(tail -n 1 "$work/output")" == 'selected=[]' ]]
# Independently verify all direct local action callers have their exact owner.
jq -e --slurpfile inventory "$root/.github/scripts/ci-selection/inventory.json" '
  all(.jobs | to_entries[] | select(.key | startswith("test-"));
    .key as $id | all(.value.steps[]? | .uses? // empty | select(startswith("./actions/"));
      (.[2:] + "/") as $owner | $inventory[0].jobs[$id] | index($owner) != null))
' "$work/workflow.json" > /dev/null

# Exercise the real binary against immutable cleanup-only Git history and the
# complete production inventory, then feed its output into the actual reducer.
fixture="$work/cleanup"
mkdir -p "$fixture/.github/workflows"
git init -q "$fixture"
git -C "$fixture" config user.name 'CI fixture'
git -C "$fixture" config user.email 'fixture@example.invalid'
git -C "$fixture" config commit.gpgsign false
printf 'base\n' > "$fixture/.github/workflows/delete-workflow-runs.yaml"
git -C "$fixture" add -- .github/workflows/delete-workflow-runs.yaml
git -C "$fixture" commit -qm 'test: cleanup baseline'
base="$(git -C "$fixture" rev-parse HEAD)"
printf 'changed\n' > "$fixture/.github/workflows/delete-workflow-runs.yaml"
git -C "$fixture" add -- .github/workflows/delete-workflow-runs.yaml
git -C "$fixture" commit -qm 'test: cleanup change'
head="$(git -C "$fixture" rev-parse HEAD)"
: > "$work/output"
EVENT_NAME=pull_request RUN_CATALOGUE=true CATALOGUE_SCOPE=true BASE_SHA="$base" HEAD_SHA="$head" GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$fixture" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
selected="$(sed -n 's/^selected=//p' "$work/output")"
jq -e '. == ["test-delete-workflow-runs-all","test-delete-workflow-runs-minimal","test-delete-workflow-runs-specific"]' <<< "$selected" > /dev/null
needs="$(jq -cn --argjson selected "$selected" 'reduce $selected[] as $id ({}; .[$id] = {result:"success"})')"
reducer="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .run' "$ci")"
JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" bash -c "$reducer"
for caller in test-delete-workflow-runs-all test-delete-workflow-runs-minimal test-delete-workflow-runs-specific; do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="skipped"' <<< "$needs")"
  if JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" bash -c "$reducer" > /dev/null 2>&1; then
    echo "FAIL: selected native cleanup caller $caller was skipped without rejection" >&2
    exit 1
  fi
done
echo 'PASS: complete job inventory, owner coverage and preserved scheduling'
