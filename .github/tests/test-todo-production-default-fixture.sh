#!/usr/bin/env bash
# Source parity and independent boundaries for native compatibility-path replay.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
production="${1:-$root/.github/workflows/scan-for-todo-comments.yaml}"
fixture="${2:-$root/.github/workflows/scan-for-todo-comments-default-fixture.yaml}"
ci="${3:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$fixture" ]] || fail 'native default-off production fixture is missing'
yq -o=json '.' "$production" >"$work/source.json"
yq -o=json '.' "$fixture" >"$work/fixture.json"
yq -o=json '.' "$ci" >"$work/ci.json"
guard() {
  jq -e '
    .permissions == {} and (.jobs | keys == ["todos"]) and
    .jobs.todos.permissions == {contents:"read"} and
    (.jobs.todos["continue-on-error"] // false) == false and
    .on.workflow_call.inputs["optional-project-auth"].default == false and
    .on.workflow_call.inputs.project.default == "organization/devantler-tech/5" and
    .on.workflow_call.inputs["fixture-skip-app-token"].default == false and
    ([.jobs.todos.steps[] | select(.id == "fixture-scan")] | length == 1 and all(
      .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" and
      .with.project == "${{ inputs.project }}" and
      .with["optional-project-auth"] == "${{ inputs.optional-project-auth }}" and
      .["continue-on-error"] == true)) and
    ([.jobs.todos.steps[] | select(.name == "Prepare default-path offline dependencies")] | length == 1 and all(
      .env.TODO_EXPECTED_PROJECT == "organization/devantler-tech/5" and
      .env.TODO_EXPECTED_PROJECT_SECRET == "offline-project-token" and
      .env.TODO_EXPECTED_TOKEN == "${{ github.token }}" and
      .env.TODO_FIXTURE_SKIP_TOKEN == "${{ inputs.fixture-skip-app-token }}" and
      (.env | keys) == ["TODO_EXPECTED_BEFORE","TODO_EXPECTED_COMMITS","TODO_EXPECTED_DIFF","TODO_EXPECTED_IGNORE","TODO_EXPECTED_PROJECT","TODO_EXPECTED_PROJECT_SECRET","TODO_EXPECTED_TOKEN","TODO_FIXTURE_SKIP_TOKEN"] and
      .shell == "bash" and .if == null and (.["continue-on-error"] // false) == false and
      .run == "bash .devantler-tech-actions/.github/tests/todo-production-default-fixture.sh prepare")) and
    ([.jobs.todos.steps[] | select(.name == "Verify native default-path replay")] | length == 1 and all(
      .if == "${{ always() }}" and
      .env.TODO_FIXTURE_OUTCOME == "${{ steps.fixture-scan.outcome }}" and
      .env.TODO_FIXTURE_SKIP_TOKEN == "${{ inputs.fixture-skip-app-token }}" and
      (.env | keys) == ["TODO_FIXTURE_OUTCOME","TODO_FIXTURE_SKIP_TOKEN"] and
      .shell == "bash" and (.["continue-on-error"] // false) == false and
      .run == "bash .devantler-tech-actions/.github/tests/todo-production-default-fixture.sh verify"))
  ' "$1" >/dev/null || return 1
  jq -e '
    . as $ci | ["test-scan-for-todo-comments-default", "test-scan-for-todo-comments-default-control"] | all(. as $id |
      $ci.jobs[$id].uses == "./.github/workflows/scan-for-todo-comments-default-fixture.yaml" and
      $ci.jobs[$id].permissions == {contents:"read"} and
      $ci.jobs[$id].secrets == null and $ci.jobs[$id].env == null and
      $ci.jobs[$id].needs == null and
      ($ci.jobs[$id]["continue-on-error"] // false) == false and
      $ci.jobs[$id].if == "${{ github.event_name != '\''merge_group'\'' && !startsWith(github.event.head_commit.message, '\''chore(main): release '\'') }}" and
      ($ci.jobs["ci-required-checks"].needs | index($id)) != null and
      any($ci.jobs["ci-required-checks"].steps[];
        (.env.JOB_RESULTS // "" | contains("needs." + $id + ".result")))) and
    $ci.jobs["test-scan-for-todo-comments-default"].with == null and
    $ci.jobs["test-scan-for-todo-comments-default-control"].with == {"fixture-skip-app-token":true}
  ' "$2" >/dev/null
}
guard "$work/fixture.json" "$work/ci.json" || fail 'default-off replay lost its native routing or read-only boundary'
# The two fixture steps and invocation bookkeeping are the only behavioral edits.
jq -S 'del(.name, .jobs["dry-run"], .jobs.todos.permissions.issues)' "$work/source.json" >"$work/expected.json"
jq -S '
  del(.name, .on.workflow_call.inputs["fixture-skip-app-token"]) |
  .jobs.todos.steps |= map(select(.name != "Prepare default-path offline dependencies" and
    .name != "Verify native default-path replay") |
    if .id == "fixture-scan" then del(.id, .["continue-on-error"]) else . end)
' "$work/fixture.json" >"$work/actual.json"
cmp -s "$work/expected.json" "$work/actual.json" || fail 'fixture differs from the complete production branch'
for mutation in \
  '.jobs.todos.permissions.issues="write"' \
  '.jobs.todos["continue-on-error"]=true' \
  '.jobs.todos.steps |= map(if .id=="fixture-scan" then .with.project="" else . end)' \
  '.on.workflow_call.inputs["optional-project-auth"].default=true' \
  '.jobs.todos.steps |= map(if .name=="Verify native default-path replay" then .["continue-on-error"]=true else . end)' \
  '.jobs.todos.steps |= map(if .name=="Verify native default-path replay" then .if="false" else . end)' \
  '.jobs.todos.steps |= map(if .name=="Prepare default-path offline dependencies" then .env.EXTRA="\u0024{{ secrets.APP_PRIVATE_KEY }}" else . end)' \
  '.jobs.todos.steps |= map(if .name=="Verify native default-path replay" then .env.TODO_FIXTURE_OUTCOME="success" else . end)'; do
  jq "$mutation" "$work/fixture.json" >"$work/bad.json"
  if guard "$work/bad.json" "$work/ci.json"; then fail 'unsafe fixture mutation accepted'; fi
done
for mutation in \
  '.jobs["test-scan-for-todo-comments-default"].with={"optional-project-auth":true}' \
  '.jobs["test-scan-for-todo-comments-default"].secrets="inherit"' \
  '.jobs["test-scan-for-todo-comments-default-control"].permissions.issues="write"' \
  '.jobs["test-scan-for-todo-comments-default-control"].with={}' \
  '.jobs["test-scan-for-todo-comments-default"].needs="skipped-job"' \
  '.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-scan-for-todo-comments-default-control.result";"needs.wrong.result") else . end)' \
  '.jobs["ci-required-checks"].needs |= map(select(.!="test-scan-for-todo-comments-default"))'; do
  jq "$mutation" "$work/ci.json" >"$work/bad.json"
  if guard "$work/fixture.json" "$work/bad.json"; then fail 'unsafe caller mutation accepted'; fi
done
bash "$root/.github/scripts/generate-todo-default-fixture.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/fixture.json" >"$work/checked.json"
cmp -s "$work/generated.json" "$work/checked.json" || fail 'canonical default fixture is stale'

# Exercise the result verifier independently so missing execution cannot be green.
export RUNNER_TEMP="$work/runtime" TODO_FIXTURE_SKIP_TOKEN=false TODO_FIXTURE_OUTCOME=success
runtime="$RUNNER_TEMP/todo-action-smoke"
mkdir -p "$runtime"
printf '{"flag":"false","project":"organization/devantler-tech/5","token":"offline-project-token"}\n' >"$runtime/app-token.json"
printf '{"case":"default"}\n' >"$runtime/expected.json"
cp "$runtime/expected.json" "$runtime/calls.jsonl"
printf 'offline-image\n' >"$runtime/pulls.jsonl"
bash "$root/.github/tests/todo-production-default-fixture.sh" verify >/dev/null
for mutation in '.project=""' '.token=""'; do
  jq "$mutation" "$runtime/app-token.json" >"$runtime/mutated.json"
  cp "$runtime/app-token.json" "$runtime/saved.json"
  cp "$runtime/mutated.json" "$runtime/app-token.json"
  if bash "$root/.github/tests/todo-production-default-fixture.sh" verify >"$work/result" 2>&1; then fail 'default runtime mutation accepted'; fi
  cp "$runtime/saved.json" "$runtime/app-token.json"
done
cat "$runtime/expected.json" >>"$runtime/calls.jsonl"
if bash "$root/.github/tests/todo-production-default-fixture.sh" verify >"$work/result" 2>&1; then fail 'duplicate scanner invocation accepted'; fi
rm "$runtime/app-token.json"
: >"$runtime/calls.jsonl"
printf 'empty-project-secret\n' >"$runtime/credential-mismatch"
TODO_FIXTURE_SKIP_TOKEN=true TODO_FIXTURE_OUTCOME=failure bash "$root/.github/tests/todo-production-default-fixture.sh" verify >/dev/null
printf 'other-failure\n' >"$runtime/credential-mismatch"
if TODO_FIXTURE_SKIP_TOKEN=true TODO_FIXTURE_OUTCOME=failure bash "$root/.github/tests/todo-production-default-fixture.sh" verify >"$work/result" 2>&1; then fail 'unrelated failure accepted as routing control'; fi
printf 'empty-project-secret\n' >"$runtime/credential-mismatch"
if TODO_FIXTURE_SKIP_TOKEN=true TODO_FIXTURE_OUTCOME=success bash "$root/.github/tests/todo-production-default-fixture.sh" verify >"$work/result" 2>&1; then fail 'successful wrapper accepted as failed control'; fi
echo 'PASS: source-derived native default-off replay, 15 boundaries and five runtime controls'
