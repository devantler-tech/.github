#!/usr/bin/env bash
# Exercise the actual selector contract and complete current workflow inventory.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ci="$root/.github/workflows/ci.yaml"
yq -o=json . "$ci" > "$work/workflow.json"
# The full reducer now consumes native queue evidence in its own allocation.
# Keep this selector integration offline while executing that same reducer.
mkdir "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api repos/devantler-tech/fixture/actions/runs/123/attempts/2/jobs?per_page=100 --paginate --slurp' ]] || exit 99
cat "$QUEUE_FIXTURE"
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" QUEUE_FIXTURE="$root/.github/tests/fixtures/queue-slots.json"
export REPOSITORY=devantler-tech/fixture RUN_ID=123 RUN_ATTEMPT=2 HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$work/preflight.jq" <<'JQ'
  .jobs["select-ci-tests"] as $s |
  (.jobs | has("catalogue-scope") | not) and
  ($s.if == "${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}") and
  ($s.needs == null) and
  ($s | has("continue-on-error") | not) and
  ($s.permissions == {"contents":"read"}) and
  ($s.outputs.selected == "${{ steps.select.outputs.selected }}") and
  ($s.outputs.catalogue == "${{ steps.scope.outputs.catalogue }}") and
  ($s.steps | length == 5) and
  ($s.steps[0].uses | startswith("step-security/harden-runner@")) and
  ([$s.steps[1], $s.steps[3]] | all(.uses | startswith("actions/checkout@"))) and
  ($s.steps[1].with == {"ref":"${{ github.event.pull_request.base.sha || github.sha }}","fetch-depth":0,"persist-credentials":false}) and
  ($s.steps[3].with == {"fetch-depth":0,"persist-credentials":false}) and
  ($s.steps[2].id == "scope") and
  ($s.steps[4].id == "select") and
  ([$s.steps[1:][] | .if] | all(. == null)) and
  ([$s.steps[] | ."continue-on-error"] | all(. == null or . == false)) and
  ([$s.steps[] | select(.id == "select") | .env.GOWORK] == ["off"]) and
  ([$s.steps[] | select(.id == "select") | .env.GOFLAGS] == [""]) and
  ([$s.steps[] | select(.id == "select") | .env.GOTOOLCHAIN] == ["local"]) and
  ([$s.steps[] | select(.id == "select") | .env.CATALOGUE_SCOPE] == ["${{ steps.scope.outputs.catalogue }}"]) and
  (.jobs["ci-required-checks"].needs | index("select-ci-tests") != null)
JQ
if ! jq -e -f "$work/preflight.jq" "$work/workflow.json" > /dev/null; then
  echo 'FAIL: classification and selection must share one runner with ordered trusted-base and candidate checkouts' >&2
  exit 1
fi
for mutation in \
  'del(.jobs["select-ci-tests"].steps[1].with.ref)' \
  '.jobs["select-ci-tests"].steps |= [.[0], .[3], .[2], .[1], .[4]]' \
  '.jobs["select-ci-tests"].steps[2].if = "false"' \
  '.jobs["select-ci-tests"].steps[2]."continue-on-error" = true' \
  '.jobs["select-ci-tests"].steps[1].with."persist-credentials" = true' \
  '.jobs["select-ci-tests"].steps[4].env.CATALOGUE_SCOPE = "true"' \
  '.jobs["select-ci-tests"].steps |= [.[0], .[1], .[4], .[3], .[2]]' \
  'del(.jobs["ci-required-checks"].needs[] | select(. == "select-ci-tests"))'; do
  jq "$mutation" "$work/workflow.json" > "$work/unsafe.json"
  if jq -e -f "$work/preflight.jq" "$work/unsafe.json" > /dev/null; then
    echo "FAIL: unsafe preflight mutation accepted: $mutation" >&2
    exit 1
  fi
done
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
# Native evidence files belong to this offline fixture, never the checkout.
run_reducer() { (cd "$work"; bash -c "$reducer"); }

JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" run_reducer || {
  echo "FAIL: intentional interface-only caller skips incorrectly failed hosted selection" >&2
  exit 1
}
# Main's push event also intentionally excludes these two reusable callees.
# Reproduce that hosted result map through the production selector and reducer.
pr_only_callers='["test-dependency-review-workflow","test-apply-signed-fixes-verifies-without-a-patch"]'
main_needs="$(jq --argjson skipped "$pr_only_callers" 'reduce $skipped[] as $id (.; .[$id].result="skipped")' <<< "$needs")"
JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$main_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$main_needs" run_reducer || {
  echo "FAIL: intentional PR-only caller skips incorrectly failed main selection" >&2
  exit 1
}
# A failed preserved call must still fail the global reducer. Expected callee
# exclusions may skip; every selected execution remains mandatory.
for caller in $(jq -nr --argjson interface "$interface_callers" --argjson pr_only "$pr_only_callers" '$interface + $pr_only | .[]'); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="failure"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer > /dev/null 2>&1; then
    echo "FAIL: failed preserved caller $caller was silently accepted" >&2
    exit 1
  fi
done
for caller in $(jq -r '.[]' <<< "$selected"); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="skipped"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer > /dev/null 2>&1; then
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
needs="$(jq -cn --argjson selected "$selected" 'reduce $selected[] as $id ({"test-enable-auto-merge-queue":{result:"skipped"}}; .[$id] = {result:"success"})')"
reducer="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .run' "$ci")"
JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" run_reducer
for caller in test-delete-workflow-runs-all test-delete-workflow-runs-minimal test-delete-workflow-runs-specific; do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="skipped"' <<< "$needs")"
  if JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer > /dev/null 2>&1; then
    echo "FAIL: selected native cleanup caller $caller was skipped without rejection" >&2
    exit 1
  fi
done

# The Go implementation belongs only to the three cleanup fixtures. Keep that
# source path classified so a focused reliability fix does not allocate the
# complete catalogue matrix merely to prove those same three callers.
source_fixture="$work/cleanup-source"
mkdir -p "$source_fixture/.github/scripts/delete-workflow-runs"
git init -q "$source_fixture"
git -C "$source_fixture" config user.name 'CI fixture'
git -C "$source_fixture" config user.email 'fixture@example.invalid'
git -C "$source_fixture" config commit.gpgsign false
printf 'package main\n' > "$source_fixture/.github/scripts/delete-workflow-runs/main.go"
git -C "$source_fixture" add -- .github/scripts/delete-workflow-runs/main.go
git -C "$source_fixture" commit -qm 'test: cleanup source baseline'
source_base="$(git -C "$source_fixture" rev-parse HEAD)"
printf 'package main\n// changed\n' > "$source_fixture/.github/scripts/delete-workflow-runs/main.go"
git -C "$source_fixture" add -- .github/scripts/delete-workflow-runs/main.go
git -C "$source_fixture" commit -qm 'test: cleanup source change'
source_head="$(git -C "$source_fixture" rev-parse HEAD)"
: > "$work/output"
EVENT_NAME=pull_request RUN_CATALOGUE=true CATALOGUE_SCOPE=true BASE_SHA="$source_base" HEAD_SHA="$source_head" GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$source_fixture" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
source_selected="$(sed -n 's/^selected=//p' "$work/output")"
jq -e '. == ["test-delete-workflow-runs-all","test-delete-workflow-runs-minimal","test-delete-workflow-runs-specific"]' <<< "$source_selected" > /dev/null
echo 'PASS: complete job inventory, owner coverage and preserved scheduling'
