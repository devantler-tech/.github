#!/usr/bin/env bash
# Evaluate reviewed-main admission and preserve UNKNOWN for hostile or incomplete contexts.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script="$root/scripts/governance-audit-admission.sh"
run_case() {
 local name="$1" event="$2" want="$3"; shift 3
 local context="${CONTEXT_OVERRIDE:-AUDIT_TEST_CONTEXT=default}" status=0
 : >"$work/output"
 env -i PATH="$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=devantler-tech/.github \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main \
  GITHUB_WORKFLOW_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_EVENT_NAME="$event" \
  GITHUB_OUTPUT="$work/output" "$context" \
  bash "$script" "$@" >"$work/log" 2>&1 || status=$?
 [[ "$status" == "$want" ]] || { echo "FAIL: $name returned $status" >&2; cat "$work/log" >&2; exit 1; }
 if [[ "$want" == 0 ]]; then
  [[ "$(cat "$work/output")" == enabled=true ]] || { echo "FAIL: $name emitted a wrong decision" >&2; exit 1; }
 else
  [[ ! -s "$work/output" ]] || { echo "FAIL: $name admitted incomplete evidence" >&2; exit 1; }
  [[ "$(cat "$work/log")" == *UNKNOWN* ]] || { echo "FAIL: $name omitted UNKNOWN" >&2; exit 1; }
 fi
 echo "PASS: $name"
}
run_case scheduled schedule 0
run_case input-free-manual workflow_dispatch 0
run_case untrusted-event pull_request 2
for override in GITHUB_ACTIONS=false GITHUB_REPOSITORY=outside/fixture GITHUB_REF=refs/heads/candidate GITHUB_WORKFLOW_REF=other GITHUB_WORKFLOW_SHA=main GITHUB_OUTPUT=; do
 CONTEXT_OVERRIDE="$override" run_case "$override" workflow_dispatch 2
done
run_case unexpected-argument schedule 2 --unexpected
run_case retired-policy-argument schedule 2 --policy "$work/unused"
CONTEXT_OVERRIDE="GITHUB_OUTPUT=$work/absent/output" run_case unwritable-output workflow_dispatch 2
