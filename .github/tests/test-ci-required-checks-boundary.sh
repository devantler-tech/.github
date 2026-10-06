#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/ci.yaml}
gate='.jobs.ci-required-checks'

fail() {
  printf 'ci-required-checks boundary: %s\n' "$1" >&2
  exit 1
}

[ -f "$workflow" ] || fail "workflow not found: $workflow"

permissions=$(yq -o=json -I=0 "$gate.permissions" "$workflow")
[ "$permissions" = '{}' ] ||
  fail "the required gate must have no token permissions, got: $permissions"

uses_steps=$(yq -r "$gate.steps[]? | select(.uses != null) | .uses" "$workflow")
[ -z "$uses_steps" ] ||
  fail "the required gate must not execute checked-out or external actions, got: $uses_steps"

step_count=$(yq -r "[$gate.steps[]? | select(.name == \"📊 Summarize workflow result\")] | length" "$workflow")
[ "$step_count" = '1' ] ||
  fail "expected exactly one inline summary step, got: $step_count"

script=$(yq -r "$gate.steps[] | select(.name == \"📊 Summarize workflow result\") | .run" "$workflow")
[ -n "$script" ] && [ "$script" != 'null' ] ||
  fail "the inline summary step has no executable script"

run_case() {
  local label=$1 input=$2 expected=$3 needle=$4 output rc=0

  output=$(JOB_RESULTS="$input" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS='[]' NEEDS_JSON='{"test-enable-auto-merge-queue":{"result":"skipped"}}' bash -c "$script" 2>&1) || rc=$?

  if [ "$expected" = pass ] && [ "$rc" -ne 0 ]; then
    fail "$label should pass, got exit $rc: $output"
  fi
  if [ "$expected" = fail ] && [ "$rc" -eq 0 ]; then
    fail "$label should fail closed, got exit 0: $output"
  fi
  if [[ "$output" != *"$needle"* ]]; then
    fail "$label should explain the result with '$needle', got: $output"
  fi
}

run_case 'success and skipped results' 'success skipped' pass 'all jobs succeeded or were skipped'
run_case 'failed result' 'success failure' fail 'failed or was cancelled'
run_case 'cancelled result' 'cancelled' fail 'failed or was cancelled'
run_case 'unknown result' 'success pending' fail "unknown job result: 'pending'"
run_case 'empty result list' '' fail 'no job results were provided'

# A successful selector cannot make a selected-but-skipped test green. Execute
# the actual reducer, not an independent model of its intended behavior.
selection_case() {
  local label=$1 selector=$2 selected=$3 needs=$4 expected=$5 rc=0 output
  # These unit cases omit the unselected queue. Include its actual skipped
  # dependency result; native queue execution is exercised by the API fixtures.
  local complete
  if complete=$(jq -c 'if type == "object" and (has("test-enable-auto-merge-queue") | not) then . + {"test-enable-auto-merge-queue":{"result":"skipped"}} else . end' <<< "$needs" 2>/dev/null); then
    needs=$complete
  fi
  output=$(JOB_RESULTS='success skipped' CATALOGUE_REQUIRED="${6:-true}" SELECTOR_RESULT="$selector" SELECTED_JOBS="$selected" NEEDS_JSON="$needs" bash -c "$script" 2>&1) || rc=$?
  if [[ "$expected" == fail && "$rc" == 0 ]]; then
    fail "$label was silently accepted"
  fi
  if [[ "$expected" == pass && "$rc" != 0 ]]; then
    fail "$label failed: $output"
  fi
}
selection_case 'selected successful test' success '["test-one"]' '{"test-one":{"result":"success"}}' pass
selection_case 'selected skipped test' success '["test-one"]' '{"test-one":{"result":"skipped"}}' fail
selection_case 'selected missing test' success '["test-one"]' '{}' fail
selection_case 'failed selector' failure '[]' '{}' fail
selection_case 'skipped selector' skipped '[]' '{}' fail
selection_case 'missing selection evidence' success '' '{}' fail
selection_case 'non-array selection evidence' success '{}' '{}' fail
selection_case 'duplicate selected jobs' success '["test-one","test-one"]' '{"test-one":{"result":"success"}}' fail
selection_case 'malformed results evidence' success '[]' 'invalid' fail
selection_case 'original excluded-event skip' skipped '' '{}' pass false
selection_case 'executed selector on excluded event' success '[]' '{}' fail false
selection_case 'manufactured excluded-event selection' skipped '["test-one"]' '{}' fail false
selection_case 'unknown event eligibility' success '[]' '{}' fail unknown

printf 'ci-required-checks boundary and behavior are enforced\n'
