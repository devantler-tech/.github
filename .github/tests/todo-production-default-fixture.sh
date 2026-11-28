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
    # The reviewed generated composite contains the offline dependencies.
    # Never rewrite a production action in a runner cache or workspace.
    ;;
  app-token)
    [[ "${OPTIONAL_PROJECT_AUTH:-}" == false && "${PROJECT:-}" == organization/devantler-tech/5 ]] ||
      fail 'production defaults did not reach the selected App-token step'
    # The production step gets its project token from the GitHub token broker,
    # under the to-do scanner's trust policy, and passes nothing else: no App key.
    [[ "${BROKER_ACTION:-}" =~ ^octo-sts/action@[0-9a-f]{40}$ ]] || fail 'the project token no longer comes from the broker action'
    [[ "${BROKER_DOMAIN:-}" == sts.platform.devantler.tech && "${BROKER_SCOPE:-}" == devantler-tech &&
      "${BROKER_IDENTITY:-}" == scan-for-todo-comments ]] || fail 'App-token dependency inputs changed'
    [[ "${BROKER_INPUTS:-}" == domain,identity,scope ]] || fail 'the broker step takes inputs beyond domain, scope and identity'
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
