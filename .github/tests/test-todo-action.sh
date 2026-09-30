#!/usr/bin/env bash
# Execute the actual credential validation, helper preservation and Docker run blocks offline.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-$root/actions/create-issues-from-todos/action.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$action" >"$work/action.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
condition="\${{ inputs.project != '' }}"
jq -e --arg condition "$condition" '
  .inputs["app-private-key"].required == false and
  ([.runs.steps[] | select(.id == "app-token")] | length == 1 and
    all(.if == $condition and .with["permission-organization-projects"] == "write")) and
  .runs.steps[0].name == "Validate project authentication" and
  .runs.steps[0].if == null and
  ([.runs.steps[] | select(.name == "📝 Create issues from TODOs")] | all(
    .env.INPUT_TOKEN == "${{ github.token }}" and
    .env.INPUT_PROJECT == "${{ inputs.project }}" and
    .env.INPUT_PROJECTS_SECRET == "${{ steps.app-token.outputs.token }}" and
    .env.INPUT_IGNORE == "${{ inputs.ignore }}" and
    (.env.TODO_TO_ISSUE_IMAGE |
      (capture("^ghcr.io/alstr/todo-to-issue-action:v(?<major>[0-9]+)[.](?<minor>[0-9]+)[.](?<patch>[0-9]+)@sha256:[0-9a-f]{64}$") // error("invalid scanner image pin")) |
      [.major,.minor,.patch] | map(tonumber) >= [5,1,15])))' \
  "$work/action.json" >/dev/null || fail 'project authentication must be optional, conditional and validated first'

for step in 'Validate project authentication' '🧰 Preserve retry helper' '📝 Create issues from TODOs'; do
  jq -er --arg step "$step" '.runs.steps[] | select(.name == $step) | .run | select(length > 0)' \
    "$work/action.json" >"$work/$step.sh"
done

# Resolve the fixture's known GitHub expressions as data, preserving multiline/quoted values.
project_env() {
  local step="$1" expression value
  jq -e --arg step "$step" --slurpfile context "$work/context.json" '
    .runs.steps[] | select(.name == $step) | (.env // {}) |
    with_entries(.value = (.value | tostring | . as $value |
      if startswith("${{") then
        if $context[0] | has($value) then $context[0][$value]
        else error("unknown expression in fixture") end
      else . end))' "$work/action.json" >"$work/projected.json"
  jq -j 'to_entries[] | .key,"\u0000",.value,"\u0000"' "$work/projected.json" >"$work/projected.env"
  while IFS= read -r -d '' expression && IFS= read -r -d '' value; do
    export "$expression=$value"
  done <"$work/projected.env"
}

# Each row supplies a credential state and the expected validation/run result.
run_case() (
  local label="$1" project="$2" key="$3" client="$4" app="$5"
  local failures="$6" attempts="$7" expected="$8" erase="$9" status=0
  local ignore=$'^ignored/|path with spaces/\\nquoted"pattern'
  if (( $# >= 10 )); then ignore="${10}"; fi
  export RUNNER_TEMP="$work/$label/temp" GITHUB_WORKSPACE="$work/$label/workspace with spaces"
  export GITHUB_ACTION_PATH="$work/$label/catalogue/actions/create-issues-from-todos"
  export GITHUB_PATH="$work/$label/path" GITHUB_REPOSITORY=offline/fixture
  export GITHUB_SHA=1111111111111111111111111111111111111111 GITHUB_ACTOR=offline-actor
  export GITHUB_API_URL=https://api.example.invalid GITHUB_SERVER_URL=https://example.invalid
  export TODO_EXPECTED_BEFORE=fixture-base TODO_EXPECTED_DIFF=https://example.invalid/pull.diff
  export TODO_EXPECTED_COMMITS=$'[{"message":"first line\\nsecond line \\"quoted\\""}]'
  export TODO_EXPECTED_IGNORE="$ignore"
  export TODO_EXPECTED_TOKEN=offline-token TODO_EXPECTED_PROJECT="$project" TODO_EXPECTED_PROJECT_SECRET=""
  [[ -z "$project" ]] || TODO_EXPECTED_PROJECT_SECRET=offline-project-token
  export TODO_FAILURES="$failures" TODO_EXPECTED_ATTEMPTS="$attempts" RETRY_BASE_DELAY=0
  mkdir -p "$RUNNER_TEMP" "$GITHUB_WORKSPACE" "$GITHUB_ACTION_PATH" "$GITHUB_ACTION_PATH/../../.scripts"
  cp "$root/.scripts/retry.sh" "$GITHUB_ACTION_PATH/../../.scripts/retry.sh"
  jq -n --arg project "$project" --arg key "$key" --arg client "$client" --arg app "$app" \
    --arg ignore "$TODO_EXPECTED_IGNORE" --arg commits "$TODO_EXPECTED_COMMITS" \
    --arg repo "$GITHUB_REPOSITORY" --arg sha "$GITHUB_SHA" --arg actor "$GITHUB_ACTOR" \
    --arg api "$GITHUB_API_URL" --arg server "$GITHUB_SERVER_URL" --arg before "$TODO_EXPECTED_BEFORE" \
    --arg diff "$TODO_EXPECTED_DIFF" '
    {"${{ inputs.project }}":$project,"${{ inputs.app-private-key }}":$key,
     "${{ inputs.client-id }}":$client,"${{ inputs.app-id }}":$app,"${{ inputs.ignore }}":$ignore,
     "${{ github.repository }}":$repo,"${{ github.sha }}":$sha,"${{ github.actor }}":$actor,
     "${{ github.api_url }}":$api,"${{ github.server_url }}":$server,"${{ github.token }}":"offline-token",
     "${{ github.event.before || github.base_ref }}":$before,"${{ toJSON(github.event.commits) }}":$commits,
     "${{ github.event.pull_request.diff_url }}":$diff,
     "${{ steps.app-token.outputs.token }}":(if $project == "" then "" else "offline-project-token" end)}' \
    >"$work/context.json"
  project_env 'Validate project authentication'
  bash "$work/Validate project authentication.sh" >"$work/validation.log" 2>&1 || status=$?
  if [[ "$expected" == invalid ]]; then
    [[ "$status" == 1 ]] || fail "$label: invalid project credentials were accepted"
    echo "PASS: $label rejected before checkout or Docker"
    return
  fi
  [[ "$status" == 0 ]] || fail "$label: valid project credential state rejected"
  bash "$root/.github/tests/todo-action-smoke.sh" prepare
  export PATH="$RUNNER_TEMP/todo-action-smoke/bin:$PATH"
  bash "$work/🧰 Preserve retry helper.sh"
  cmp "$root/.scripts/retry.sh" "$RUNNER_TEMP/devantler-actions-retry.sh" >/dev/null ||
    fail "$label: preserved retry helper differs"
  if [[ "$erase" == true ]]; then rm -rf "$work/$label/catalogue"; fi
  project_env '📝 Create issues from TODOs'
  status=0
  bash "$work/📝 Create issues from TODOs.sh" >"$work/run.log" 2>&1 || status=$?
  [[ "$status" == "$expected" ]] || fail "$label: expected exit $expected, got $status"
  bash "$root/.github/tests/todo-action-smoke.sh" verify >/dev/null ||
    fail "$label: exact Docker projection or retry count changed"
  echo "PASS: $label"
)

run_case no-project '' '' '' '' 0 1 0 false ''
run_case unused-project-credentials '' offline-key offline-client '' 0 1 0 false
run_case project-client organization/offline/1 offline-key offline-client '' 0 1 0 false
run_case project-legacy-app organization/offline/1 offline-key '' 12345 0 1 0 false
run_case project-missing-key organization/offline/1 '' offline-client '' 0 0 invalid false
run_case project-missing-identity organization/offline/1 offline-key '' '' 0 0 invalid false
run_case project-conflicting-identities organization/offline/1 offline-key offline-client 12345 0 0 invalid false
run_case transient-recovery '' '' '' '' 2 3 0 false
run_case terminal-failure '' '' '' '' -1 3 73 false
run_case preserved-helper-after-checkout '' '' '' '' 2 3 0 true
echo 'PASS: 10 offline to-do wrapper scenarios preserve inputs, credentials and failures'
