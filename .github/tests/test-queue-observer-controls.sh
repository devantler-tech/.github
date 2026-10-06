#!/usr/bin/env bash
# Prove realistic observer regressions fail through the behavioral fixtures.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/ci.json"
count=0
# Inject one observer regression and require its behavioral failure diagnostic.
mutation() {
  local old="$1" replacement="$2" diagnostic="$3"
  jq --arg old "$old" --arg replacement "$replacement" '
    (.jobs["ci-required-checks"].steps[]
      | select(.name == "📊 Summarize workflow result").run)
    |= (if contains($old) then split($old) | join($replacement) else error("missing mutation anchor") end)
  ' "$work/ci.json" >"$work/mutated.json"
  if bash "$root/.github/tests/test-queue-observer.sh" "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: observer regression was accepted: $old" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
}
mutation 'for attempt in 1 2 3' 'for attempt in 1' 'transient API failure then complete success'
mutation '> jobs.json' '>> jobs.json' 'transient API failure then complete success'
mutation "if [[ \"\$attempt\" == 3 || ! \"\$status\" =~ ^5[0-9][0-9]$ ]]; then" \
  "if [[ \"\$attempt\" == 3 ]]; then" 'HTTP 401) accepted invalid evidence'
mutation "and .run_id == \$run and .run_attempt == \$attempt" \
  "and .run_id == \$run" 'different attempt accepted invalid evidence'
mutation 'and ((map(.jobs | length) | add) == .[0].total_count)' \
  '' 'extra uncounted job accepted invalid evidence'
mutation 'and ([.[] | .jobs[].id] | length == (unique | length))' \
  '' 'duplicate job identity accepted invalid evidence'
mutation 'and .head_sha == $head' '' 'different head accepted invalid evidence'
mutation '.status == "completed" and .conclusion == "success"' \
  '.status == "completed"' 'failed queue slot accepted invalid evidence'

# Exercise the consuming required gate too: a proof that never runs, a tolerated
# error, or a wrong provider binding must not make its check green.
gate_control() {
  local diagnostic="$1"
  if bash "$root/.github/tests/test-native-queue-gate.sh" "$work/mutated.json" > "$work/result" 2>&1; then
    echo 'FAIL: disconnected native queue gate was accepted' >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || { cat "$work/result" >&2; exit 1; }
  count=$((count + 1))
}
jq '(.jobs["ci-required-checks"].steps[] | select(.name == "📊 Summarize workflow result").run) |= sub("queue_result=.*"; "queue_result=skipped")' \
  "$work/ci.json" > "$work/mutated.json"
gate_control 'rejects a successful matrix with missing native queue slot 2 expected fail, got exit 0'
jq '.jobs["ci-required-checks"]["continue-on-error"] = true' "$work/ci.json" > "$work/mutated.json"
gate_control 'required gate tolerates a native proof failure'
jq '(.jobs["ci-required-checks"].steps[] | select(.name == "📊 Summarize workflow result").env.HEAD_SHA) = "${{ github.sha }}"' \
  "$work/ci.json" > "$work/mutated.json"
gate_control 'native queue proof lacks exact provider head and attempt bindings'
echo "PASS: $count independent observer regressions rejected"
