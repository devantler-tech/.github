#!/usr/bin/env bash
# Preserve exactly one successful result from the actual shared retry helper.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/temp"
cat >"$work/producer" <<'PRODUCER'
#!/usr/bin/env bash
set -euo pipefail
attempt=$(( $(cat "$CASE_DIR/count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$attempt" >"$CASE_DIR/count"
printf 'diagnostic attempt %s\n' "$attempt" >&2
if [[ "$attempt" -le "$FAILURES" ]]; then
  printf 'partial\000failed\n'
  exit 7
fi
if [[ "${TERMINATE:-false}" == true ]]; then
  kill -TERM "$PPID"
fi
printf 'success\000\r\n\n'
PRODUCER
chmod +x "$work/producer"
run_case() {
  local label="$1" failures="$2" attempts="$3" expected_status="$4" terminate="${5:-false}" status=0
  mkdir "$work/$label"
  CASE_DIR="$work/$label" FAILURES="$failures" TERMINATE="$terminate" TMPDIR="$work/temp" \
    RETRY_MAX_ATTEMPTS="$attempts" RETRY_BASE_DELAY=0 RETRY_MAX_DELAY=0 \
    bash "$root/.scripts/retry.sh" "$work/producer" >"$work/$label/stdout" 2>"$work/$label/stderr" || status=$?
  [[ "$status" == "$expected_status" ]] || { echo "FAIL: $label status $status" >&2; exit 1; }
  if [[ "$expected_status" == 0 ]]; then
    printf 'success\000\r\n\n' >"$work/expected"
    cmp "$work/expected" "$work/$label/stdout"
  else
    [[ ! -s "$work/$label/stdout" ]] || { echo "FAIL: failed attempt stdout escaped" >&2; exit 1; }
  fi
  [[ "$(cat "$work/$label/count")" == "$attempts" ]] || { echo "FAIL: wrong attempt bound" >&2; exit 1; }
  [[ -z "$(ls -A "$work/temp")" ]] || { echo "FAIL: retry buffer remained" >&2; exit 1; }
  grep -qF "diagnostic attempt $attempts" "$work/$label/stderr"
  echo "PASS: retry result $label"
}
run_case first-success 0 1 0
run_case partial-then-success 2 3 0
run_case exhausted 3 3 7
run_case terminated 0 1 143 true

echo 'PASS: retry output preserves binary bytes, last status, stderr and buffer cleanup'
