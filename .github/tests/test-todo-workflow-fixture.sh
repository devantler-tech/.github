#!/usr/bin/env bash
# The reusable workflow must never accept a skipped or retried smoke as one execution.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export RUNNER_TEMP="$work" GITHUB_PATH="$work/path" GITHUB_WORKSPACE="$work/workspace"
export GITHUB_REPOSITORY=fixture/repo GITHUB_SHA=fixture-sha GITHUB_ACTOR=fixture-actor
export GITHUB_API_URL=https://api.invalid GITHUB_SERVER_URL=https://github.invalid
export TODO_EXPECTED_TOKEN=synthetic-read-only-token
export TODO_EXPECTED_IGNORE='^\.github/tests/'
fixture="$work/todo-action-smoke"
bash "$root/.github/tests/todo-action-smoke.sh" prepare
jq -c '.' "$fixture/expected.json" >"$work/expected-call"
for count in 0 1 2; do
  : >"$fixture/calls.jsonl"
  for ((i = 0; i < count; i++)); do cat "$work/expected-call" >>"$fixture/calls.jsonl"; done
  # A zero-attempt override must not create a vacuous success.
  if TODO_EXPECTED_ATTEMPTS=0 bash "$root/.github/tests/todo-action-smoke.sh" verify-once >"$work/result" 2>&1; then
    [[ "$count" == 1 ]] || {
      echo "FAIL: $count executions accepted" >&2
      exit 1
    }
  else
    [[ "$count" != 1 ]] || {
      cat "$work/result" >&2
      exit 1
    }
    grep -qF 'Docker attempts, arguments or forwarded inputs differ' "$work/result"
  fi
done
jq -c '.env.INPUT_IGNORE=""' "$work/expected-call" >"$fixture/calls.jsonl"
if bash "$root/.github/tests/todo-action-smoke.sh" verify-once >"$work/result" 2>&1; then
  echo 'FAIL: broken ignore forwarding accepted' >&2
  exit 1
fi
grep -qF 'Docker attempts, arguments or forwarded inputs differ' "$work/result"
echo 'PASS: exact-one verifier rejects skipped/retried execution and broken inputs'
