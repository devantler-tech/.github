#!/usr/bin/env bash
# Replace external dependencies only; GitHub evaluates the source inputs and ifs.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="${RUNNER_TEMP:?}/todo-action-smoke"
fail() { echo "FAIL: $*" >&2; exit 1; }
case "${1:-}" in
  prepare)
    bash "$root/.github/tests/todo-action-smoke.sh" prepare
    rm -f "$fixture/app-token.json"
    action="$root/actions/create-issues-from-todos/action.yaml"
    yq -o=json '.' "$action" >"$fixture/production-action.json"
    jq -e '
      [.runs.steps[] | select(.id == "app-token")] | length == 1 and
      all(.uses | startswith("actions/create-github-app-token@"))
    ' "$fixture/production-action.json" >/dev/null || fail 'missing source App-token dependency'
    jq --arg skip "${TODO_FIXTURE_SKIP_TOKEN:?}" '
      .runs.steps |= map(
        if .id == "app-token" then
          .env = {CLIENT_ID:.with["client-id"], APP_ID:.with["app-id"],
            APP_PRIVATE_KEY:.with["private-key"], PROJECT_PERMISSION:.with["permission-organization-projects"],
            OPTIONAL_PROJECT_AUTH:"${{ inputs.optional-project-auth }}", PROJECT:"${{ inputs.project }}"} |
          del(.uses, .with) | .shell = "bash" |
          .run = "bash \"${GITHUB_ACTION_PATH}/../../.github/tests/todo-production-default-fixture.sh\" app-token" |
          if $skip == "true" then .if = "false" else . end
        elif (.uses // "" | startswith("actions/checkout@")) then
          del(.uses, .with) | .shell = "bash" |
          .run = "echo Offline checkout dependency: no workspace changes"
        else . end)
    ' "$fixture/production-action.json" >"$fixture/offline-action.json"
    yq -P '.' "$fixture/offline-action.json" >"$action"
    ;;
  app-token)
    [[ "${OPTIONAL_PROJECT_AUTH:-}" == false && "${PROJECT:-}" == organization/devantler-tech/5 ]] ||
      fail 'production defaults did not reach the selected App-token step'
    [[ -z "${APP_PRIVATE_KEY:-}" ]] || fail 'offline replay received a real credential'
    [[ "${PROJECT_PERMISSION:-}" == write ]] || fail 'App-token dependency inputs changed'
    [[ ! -e "$fixture/app-token.json" ]] || fail 'App-token dependency ran more than once'
    jq -n --arg flag "$OPTIONAL_PROJECT_AUTH" --arg project "$PROJECT" \
      '{flag:$flag,project:$project,token:"offline-project-token"}' >"$fixture/app-token.json"
    printf 'token=offline-project-token\n' >>"${GITHUB_OUTPUT:?}"
    echo 'PASS: native default-off routing selected the offline App-token dependency'
    ;;
  verify)
    case "${TODO_FIXTURE_SKIP_TOKEN:?}" in
      false)
        [[ "${TODO_FIXTURE_OUTCOME:-}" == success ]] || fail 'default-off production invocation failed'
        jq -e '. == {flag:"false",project:"organization/devantler-tech/5",token:"offline-project-token"}' \
          "$fixture/app-token.json" >/dev/null || fail 'App-token dependency did not execute with production defaults'
        [[ ! -e "$fixture/credential-mismatch" ]] || fail 'unexpected credential forwarding mismatch'
        bash "$root/.github/tests/todo-action-smoke.sh" verify-once
        echo 'PASS: native default-off production path preserves project and token forwarding'
        ;;
      true)
        [[ "${TODO_FIXTURE_OUTCOME:-}" == failure && ! -e "$fixture/app-token.json" ]] ||
          fail 'broken App-token routing did not fail the actual wrapper'
        [[ "$(cat "$fixture/credential-mismatch")" == empty-project-secret ]] ||
          fail 'negative control failed without exercising the project-secret boundary'
        [[ ! -s "$fixture/calls.jsonl" ]] || fail 'broken credential state reached an accepted Docker invocation'
        rm -f "$fixture/credentials.json"
        echo 'PASS: skipping the selected App-token step fails at the offline scanner boundary'
        ;;
      *) fail 'unexpected negative-control value' ;;
    esac
    ;;
  *) echo 'usage: todo-production-default-fixture.sh <prepare|app-token|verify>' >&2; exit 2 ;;
esac
