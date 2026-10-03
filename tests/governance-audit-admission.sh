#!/usr/bin/env bash
# Evaluate the actual admission script with both rollout states and hostile contexts.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script="$root/scripts/governance-audit-admission.sh"
[[ -f "$script" ]] || {
  echo 'FAIL: governance admission is missing' >&2
  exit 1
}
printf '%s' '{"scheduled":false}' >"$work/off.json"
printf '%s' '{"scheduled":true}' >"$work/on.json"
run_case() {
  local name="$1" event="$2" requested="$3" policy="$4" want="$5" decision="${6:-}" status=0
  local context="${CONTEXT_OVERRIDE:-AUDIT_TEST_CONTEXT=default}"
  : >"$work/output"
  env -i PATH="$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=devantler-tech/.github \
    GITHUB_REF=refs/heads/main \
    GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main \
    GITHUB_WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_EVENT_NAME="$event" \
    GITHUB_OUTPUT="$work/output" REQUESTED="$requested" "$context" \
    bash "$script" --policy "$policy" >"$work/log" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || {
    echo "FAIL: $name returned $status" >&2
    cat "$work/log" >&2
    exit 1
  }
  if [[ "$want" == 0 ]]; then
    [[ "$(cat "$work/output")" == "enabled=$decision" ]] || {
      echo "FAIL: $name emitted a wrong decision" >&2
      exit 1
    }
  else
    [[ ! -s "$work/output" ]] || {
      echo "FAIL: $name admitted incomplete evidence" >&2
      exit 1
    }
  fi
  echo "PASS: $name"
}
run_case scheduled-default-off schedule '' "$work/off.json" 0 false
run_case scheduled-enabled schedule '' "$work/on.json" 0 true
run_case manual-off workflow_dispatch false "$work/on.json" 0 false
run_case manual-default-off workflow_dispatch '' "$work/off.json" 0 false
run_case manual-opt-in workflow_dispatch true "$work/off.json" 0 true
run_case malformed-input workflow_dispatch yes "$work/off.json" 2
run_case untrusted-event pull_request true "$work/on.json" 2
for override in GITHUB_ACTIONS=false GITHUB_REPOSITORY=outside/fixture GITHUB_REF=refs/heads/candidate GITHUB_WORKFLOW_REF=other GITHUB_WORKFLOW_SHA=main; do
  CONTEXT_OVERRIDE="$override" run_case "$override" workflow_dispatch true "$work/on.json" 2
done
for policy in '{"scheduled":"true"}' '{"scheduled":null}' '{}' '{"scheduled":true,"extra":true}' '{bad' '{"scheduled":true}{"scheduled":true}'; do
  printf '%s' "$policy" >"$work/bad.json"
  run_case invalid-policy schedule '' "$work/bad.json" 2
done
run_case missing-policy schedule '' "$work/missing" 2
