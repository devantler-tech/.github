#!/usr/bin/env bash
# The entire TODO workflow invocation must fit a read-only token ceiling.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
projection="${1:-$root/.github/workflows/scan-for-todo-comments-readonly.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
production="${3:-$root/.github/workflows/scan-for-todo-comments.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$ci" >"$work/ci.json"
jq -e '
  . as $ci | ["test-scan-for-todo-comments", "test-scan-for-todo-comments-ignore"] | all(. as $id |
    $ci.jobs[$id].permissions == {contents:"read"})
' "$work/ci.json" >/dev/null || {
  echo 'FAIL: TODO callers must grant only contents-read' >&2
  exit 1
}
yq -o=json '.' "$projection" >"$work/projection.json"
yq -o=json '.' "$production" >"$work/production.json"
# Deliberately normalize independently of the generator, which also earns parity.
jq -S 'del(.name, .jobs.todos.permissions.issues)' "$work/production.json" >"$work/expected.json"
jq -S 'del(.name, .jobs.todos.permissions.issues)' "$work/projection.json" >"$work/actual.json"
cmp -s "$work/expected.json" "$work/actual.json" || {
  echo 'FAIL: TODO projection changed production behavior; regenerate it' >&2
  exit 1
}
jq -e '
  .name == "📝 Scan for TODO Comments (Read-Only)" and .permissions == {} and
  (.jobs | keys == ["dry-run", "todos"]) and
  .jobs.todos.permissions == {contents:"read"} and
  .jobs["dry-run"].permissions == {contents:"read"}
' "$work/projection.json" >/dev/null || {
  echo 'FAIL: TODO projection must keep every job read-only' >&2
  exit 1
}
jq -e '
  [.jobs | to_entries[] | select(.value.uses == "./.github/workflows/scan-for-todo-comments.yaml" or
    .value.uses == "./.github/workflows/scan-for-todo-comments-readonly.yaml") | .key] |
  sort == ["test-scan-for-todo-comments", "test-scan-for-todo-comments-ignore", "test-scan-for-todo-comments-no-project"]
' "$work/ci.json" >/dev/null || {
  echo 'FAIL: unexpected TODO workflow caller' >&2
  exit 1
}
jq -e '
  ["test-scan-for-todo-comments", "test-scan-for-todo-comments-ignore"] as $ids |
  . as $ci | all($ids[]; . as $id | $ci.jobs[$id] |
    .uses == "./.github/workflows/scan-for-todo-comments-readonly.yaml" and
    .secrets == null and .env == null and .with["dry-run"] == true) and
  $ci.jobs["test-scan-for-todo-comments"].with == {"dry-run":true} and
  $ci.jobs["test-scan-for-todo-comments-ignore"].with == {"dry-run":true, ignore:"^\\.github/tests/"}
' "$work/ci.json" >/dev/null || {
  echo 'FAIL: TODO smoke must use the secret-free read-only entrypoint and preserve inputs' >&2
  exit 1
}
# The production steps run with the same complete read-only projection. Exclude
# all sources and grant no issue-write ceiling even if the scanner regresses.
guard_no_project() {
  jq -e '
    .jobs["test-scan-for-todo-comments-no-project"] as $job |
    $job.uses == "./.github/workflows/scan-for-todo-comments-readonly.yaml" and
    $job.permissions == {contents:"read"} and $job.secrets == null and $job.env == null and
    $job.with == {"dry-run":false,"optional-project-auth":true,project:"",ignore:".*"} and
    $job.if == "${{ github.event_name != '\''merge_group'\'' && !startsWith(github.event.head_commit.message, '\''chore(main): release '\'') }}" and
    $job.needs == null and ($job["continue-on-error"] // false) == false and
    (.jobs["ci-required-checks"].needs | index("test-scan-for-todo-comments-no-project")) != null and
    any(.jobs["ci-required-checks"].steps[];
      (.env.JOB_RESULTS // "" | contains("needs.test-scan-for-todo-comments-no-project.result")) and
      (.run // "" | contains("$JOB_RESULTS")))
  ' "$1" >/dev/null
}
guard_no_project "$work/ci.json" || { echo 'FAIL: no-project production evaluation lost its read-only execution boundary' >&2; exit 1; }
for mutation in \
  '.jobs["test-scan-for-todo-comments-no-project"].permissions.issues="write"' \
  '.jobs["test-scan-for-todo-comments-no-project"].with.project="organization/devantler-tech/5"' \
  '.jobs["test-scan-for-todo-comments-no-project"].with.ignore=""' \
  '.jobs["test-scan-for-todo-comments-no-project"].with["optional-project-auth"]=false' \
  '.jobs["test-scan-for-todo-comments-no-project"].if="false"' \
  '.jobs["ci-required-checks"].needs |= map(select(. != "test-scan-for-todo-comments-no-project"))'; do
  jq "$mutation" "$work/ci.json" >"$work/mutated-ci.json"
  if guard_no_project "$work/mutated-ci.json"; then
    echo 'FAIL: no-project evaluation regression accepted' >&2; exit 1
  fi
done

# Reuse the existing independent execution/gate controls for both entrypoints.
bash "$root/.github/tests/test-todo-workflow-dry-run.sh" "$production" "$ci" --guard-only
jq '.jobs.todos.permissions.issues="write"' "$work/projection.json" >"$work/writable.json"
bash "$root/.github/tests/test-todo-workflow-dry-run.sh" "$work/writable.json" "$ci" --guard-only
bash "$root/.github/scripts/generate-todo-readonly.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/projection.json" >"$work/checked.json"
cmp -s "$work/generated.json" "$work/checked.json" || {
  echo 'FAIL: TODO generator differs from independent read-only projection' >&2
  exit 1
}
echo 'PASS: complete TODO projection and three callers have a read-only token ceiling'
