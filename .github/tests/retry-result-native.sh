#!/usr/bin/env bash
# Preserve exactly one successful result from the actual shared retry helper.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
nested_pid=''
cleanup() {
  [[ -z "$nested_pid" ]] || kill -KILL "$nested_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
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

# The real installer wrapper launches its own process. Cancellation must stop
# that installer as well as the immediate Bash child, without a network call.
mkdir "$work/nested" "$work/nested-bin" "$work/install-temp"
cat >"$work/nested-bin/gh" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$CASE_DIR/installer-pid"
printf '%s\n' "$PPID" >"$CASE_DIR/wrapper-pid"
while true; do
  printf 'still installing\n' >>"$CASE_DIR/installed"
  sleep 0.02
done
INSTALLER
chmod +x "$work/nested-bin/gh"
CASE_DIR="$work/nested" PATH="$work/nested-bin:$PATH" TMPDIR="$work/temp" \
  "$timeout_cmd" 3 bash "$root/.scripts/retry.sh" env TMPDIR="$work/install-temp" \
    bash "$root/.scripts/gh-skill-install.sh" offline-fixture \
  >"$work/nested/stdout" 2>"$work/nested/stderr" &
supervisor=$!
for ((i=0; i<100; i++)); do
  [[ ! -s "$work/nested/installed" ]] || break
  sleep 0.01
done
[[ -s "$work/nested/installed" ]] || { echo 'FAIL: nested installer did not start' >&2; exit 1; }
nested_pid="$(cat "$work/nested/installer-pid")"
helper_pid="$(ps -o ppid= -p "$(cat "$work/nested/wrapper-pid")" | tr -d ' ')"
[[ "$helper_pid" =~ ^[1-9][0-9]*$ ]] || { echo 'FAIL: nested helper identity missing' >&2; exit 1; }
kill -TERM "$helper_pid"
status=0
wait "$supervisor" || status=$?
[[ "$status" == 143 && ! -s "$work/nested/stdout" && -z "$(ls -A "$work/temp")" ]] || { echo "FAIL: nested cancellation status $status" >&2; exit 1; }
if kill -0 "$nested_pid" 2>/dev/null; then
  state="$(ps -o stat= -p "$nested_pid" 2>/dev/null || true)"
  [[ "$state" == Z* ]] || { echo 'FAIL: cancelled nested installer remained running' >&2; exit 1; }
fi
nested_pid=''

echo 'PASS: retry output preserves binary bytes, last status, stderr and buffer cleanup'
