#!/usr/bin/env bash
# Preserve exactly one successful result from the actual shared retry helper.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/temp"
timeout_cmd="$(command -v timeout || command -v gtimeout)"
cat >"$work/producer" <<'PRODUCER'
#!/usr/bin/env bash
set -euo pipefail
attempt=$(( $(cat "$CASE_DIR/count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$attempt" >"$CASE_DIR/count"
printf '%s\n' "$$" >"$CASE_DIR/producer-pid"
printf '%s\n' "$PPID" >"$CASE_DIR/helper-pid"
printf 'diagnostic attempt %s\n' "$attempt" >&2
printf 'created by the consumer\n' >"$CASE_DIR/consumer-file"
if [[ "$attempt" -le "$FAILURES" ]]; then
  printf 'partial\000failed\n'
  exit 7
fi
if [[ "${TERMINATE:-false}" == true ]]; then
  kill -TERM "$PPID"
  while true; do sleep 1; done
fi
printf 'success\000\r\n\n'
PRODUCER
chmod +x "$work/producer"
run_case() {
  local label="$1" failures="$2" attempts="$3" expected_status="$4" terminate="${5:-false}" status=0
  mkdir "$work/$label"
  (
  umask 022
  CASE_DIR="$work/$label" FAILURES="$failures" TERMINATE="$terminate" TMPDIR="$work/temp" \
    RETRY_MAX_ATTEMPTS="$attempts" RETRY_BASE_DELAY=0 RETRY_MAX_DELAY=0 \
    "$timeout_cmd" 3 bash "$root/.scripts/retry.sh" "$work/producer"
  ) >"$work/$label/stdout" 2>"$work/$label/stderr" || status=$?
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
  if [[ "$terminate" == true ]] && kill -0 "$(cat "$work/$label/producer-pid")" 2>/dev/null; then
    echo 'FAIL: interrupted producer remained alive' >&2
    exit 1
  fi
  local mode
  mode="$(stat -c '%a' "$work/$label/consumer-file" 2>/dev/null || stat -f '%OLp' "$work/$label/consumer-file")"
  [[ "$mode" == 644 ]] || { echo 'FAIL: retry changed consumer file permissions' >&2; exit 1; }
  echo "PASS: retry result $label"
}
run_case first-success 0 1 0
run_case partial-then-success 2 3 0
run_case exhausted 3 3 7
run_case terminated 0 1 143 true

printf 'stdin\000\r\n\n' >"$work/input"
TMPDIR="$work/temp" bash "$root/.scripts/retry.sh" cat <"$work/input" >"$work/output"
cmp "$work/input" "$work/output"

# Signal the actual helper during backoff, retaining a bounded outer deadline.
mkdir "$work/backoff"
CASE_DIR="$work/backoff" FAILURES=5 TMPDIR="$work/temp" \
  RETRY_MAX_ATTEMPTS=3 RETRY_BASE_DELAY=30 RETRY_MAX_DELAY=30 \
  "$timeout_cmd" 3 bash "$root/.scripts/retry.sh" "$work/producer" \
  >"$work/backoff/stdout" 2>"$work/backoff/stderr" &
supervisor=$!
for ((i=0; i<100; i++)); do
  if grep -qF 'retrying in 30s' "$work/backoff/stderr"; then break; fi
  sleep 0.01
done
grep -qF 'retrying in 30s' "$work/backoff/stderr" || { echo 'FAIL: no backoff started' >&2; exit 1; }
kill -TERM "$(cat "$work/backoff/helper-pid")"
status=0
wait "$supervisor" || status=$?
[[ "$status" == 143 && ! -s "$work/backoff/stdout" && -z "$(ls -A "$work/temp")" ]] || { echo "FAIL: backoff cancellation status $status" >&2; exit 1; }

echo 'PASS: retry output preserves binary bytes, last status, stderr and buffer cleanup'
