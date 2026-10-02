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
    (.jobs["test-enable-auto-merge-queue-results"].steps[]
      | select(.name == "🧪 Verify every slot completed in this run attempt").run)
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
echo "PASS: $count independent observer regressions rejected"
