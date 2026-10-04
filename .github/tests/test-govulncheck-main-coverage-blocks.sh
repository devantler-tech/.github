#!/usr/bin/env bash
# Failing-input counterpart to test-govulncheck-main-coverage.sh, per the repo convention
# that a gating self-test carries BOTH a passes-on-good-input and a blocks-on-bad-input
# test (AGENTS.md, "Failure-mode coverage for gating workflows").
#
# The guard it exercises is a *gate*: its job is to fail when the govulncheck trigger
# conditions would leave a default branch unscanned, or would run a scan
# outside the default-branch or pull-request event boundaries. A happy-path test alone cannot catch a guard
# that has silently stopped biting — and this guard is unusually easy to make vacuous,
# because its checks are structural string analysis over an expression. A regression in
# `defun`/`strip_groups`/`split_arms` (say, one that makes `$top_level` always empty, or
# yields zero arms) would leave every assertion trivially satisfied and the positive test
# still green.
#
# Each fixture in ./govulncheck-main-coverage-fixture/ reproduces ONE way the trigger can
# be wrong, and all of them are generated from a single base by `generate.sh`, so a
# fixture differs from `good.yaml` only in the defect it is named for. Asserting the
# *expected message* rather than merely a non-zero exit is what stops an operational error
# (a typo'd path, a missing yq) from false-passing as "the gate bit".
#
# Two controls guard the opposite failure — a guard that rejects everything would satisfy
# every assertion above:
#   * `good.yaml` must PASS. It is the base the bad fixtures are derived from, so this
#     proves each one's rejection is caused by its defect and not by the shared scaffold.
#   * the REAL workflow must PASS.
#
# The fixtures live outside .github/workflows/ so no real gate ever scans them.

set -euo pipefail

guard="${1:-.github/tests/test-govulncheck-main-coverage.sh}"
fixtures="${2:-.github/tests/govulncheck-main-coverage-fixture}"

status=0

check() {
  local fixture="$1" expected="$2" out rc
  local path="$fixtures/$fixture"

  if [[ ! -f "$path" ]]; then
    echo "::error::fixture $path is missing — the negative test cannot prove the gate bites"
    status=1
    return
  fi

  out="$(bash "$guard" "$path" 2>&1)" && rc=0 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "::error file=$path::the guard PASSED a deliberately-bad fixture — it has stopped biting. Expected it to report: $expected"
    status=1
  elif ! grep -qF "$expected" <<<"$out"; then
    echo "::error file=$path::the guard failed, but not for the expected reason. Expected a message containing: $expected"
    while IFS= read -r line; do echo "    got: $line"; done <<<"$out"
    status=1
  else
    echo "blocks $fixture ✅"
  fi
}

# The event fixture must isolate exactly the extra event constraint. A malformed
# completion comparison could otherwise make its generic rejection false-pass.
good_gate="$(yq -r '.jobs.govulncheck.if' "$fixtures/good.yaml")"
event_gate="$(yq -r '.jobs.govulncheck.if' "$fixtures/default-arm-event-gated.yaml")"
ran_proof="needs.changes.outputs.go != ''"
event_constraint="github.event_name == 'push' && needs.changes.outputs.go != ''"
expected_event_gate="${good_gate/"$ran_proof"/"$event_constraint"}"
if [[ "$event_gate" != "$expected_event_gate" ]]; then
  echo "::error::default-arm-event-gated fixture does not isolate only the additional event condition"
  status=1
fi

# Reachability of the default-branch scan.
check event-gated.yaml \
  "AND-s 'github.event_name ==' at the top level"
check no-default-branch-clause.yaml \
  "has no default-branch clause"
check default-branch-and-ed.yaml \
  "AND-s the path filter (needs.changes.outputs.go) at the top level"
check path-filter-inside-function-call.yaml \
  "AND-s the path filter (needs.changes.outputs.go) at the top level"
check top-level-ref-predicate.yaml \
  "AND-s a top-level ref predicate"

# Default-branch coverage and the pull-request-only scope of other arms.
check default-arm-event-gated.yaml \
  "the default-branch arm has an additional gate"
check extra-arm-not-pr-gated.yaml \
  "a non-default-branch OR-arm is not restricted to pull requests"

# The allowlist trigger, in both directions.
check missing-allowlist-entries.yaml \
  "omits '**/.govulncheck-allow.txt'"
check allowlist-in-shared-go-filter.yaml \
  "the shared 'go' path filter lists '.govulncheck-allow.txt'"
check govulncheck-output-not-consumed.yaml \
  "is never read by the govulncheck job's gate"
check missing-govulncheck-output.yaml \
  "does not expose a 'govulncheck' output"
check allow-file-not-working-dir-relative.yaml \
  "'allow-file' is not composed from 'inputs.working-directory'"

# ── Controls: the guard must accept correct input ────────────────────────────────
passes() {
  local label="$1" path="$2" out rc
  if [[ ! -f "$path" ]]; then
    echo "::error::$path is missing — the accept-side control cannot run"
    status=1
    return
  fi
  out="$(bash "$guard" "$path" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "passes $label ✅"
  else
    echo "::error file=$path::the guard REJECTS $label; the negative fixtures above prove nothing about a gate that fails everything"
    while IFS= read -r line; do echo "    got: $line"; done <<<"$out"
    status=1
  fi
}

# The fixture base. Without this, a bad fixture's rejection could come from the shared
# scaffold rather than from its defect, and every assertion above would still pass.
passes "the good fixture" "$fixtures/good.yaml"
# The workflow this guard actually protects.
passes "the real workflow" ".github/workflows/validate-go-project.yaml"

if [[ "$status" -eq 0 ]]; then
  echo "govulncheck trigger guard blocks every bad-input fixture and accepts both controls ✅"
fi

exit "$status"
