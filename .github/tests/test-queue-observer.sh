#!/usr/bin/env bash
# Exercise CI's actual queue observer against complete and failed API reads.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -r '.jobs.test-enable-auto-merge-queue-results.steps[] | select(.name == "🧪 Verify every slot completed in this run attempt") | .run' \
  "${1:-$repo_root/.github/workflows/ci.yaml}" >"$work/observer.sh"
[[ -s "$work/observer.sh" && "$(cat "$work/observer.sh")" != null ]] || exit 1
mkdir "$work/bin"
cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api repos/devantler-tech/fixture/actions/runs/123/attempts/2/jobs?per_page=100 --paginate --slurp' ]] || exit 99
count=0
[[ ! -f "$FIXTURE/count" ]] || read -r count <"$FIXTURE/count"
count=$((count + 1))
printf '%s\n' "$count" >"$FIXTURE/count"
cat "$FIXTURE/response-$count"
cat "$FIXTURE/error-$count" >&2
read -r status <"$FIXTURE/status-$count"
exit "$status"
SH
cat >"$work/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE/sleeps"
SH
chmod +x "$work/bin/gh" "$work/bin/sleep"
cat >"$work/good.json" <<'JSON'
[
  {"total_count":4,"jobs":[
    {"id":1,"run_id":123,"run_attempt":2,"name":"[Test] Enable Auto-Merge - Queue Slot 1","status":"completed","conclusion":"success"},
    {"id":2,"run_id":123,"run_attempt":2,"name":"[Test] Enable Auto-Merge - Queue Slot 2","status":"completed","conclusion":"success"}
  ]},
  {"total_count":4,"jobs":[
    {"id":3,"run_id":123,"run_attempt":2,"name":"[Test] Enable Auto-Merge - Queue Slot 3","status":"completed","conclusion":"success"},
    {"id":4,"run_id":123,"run_attempt":2,"name":"Unrelated check","status":"in_progress","conclusion":null}
  ]}
]
JSON
# Stop the suite with a diagnostic when an observer assertion fails.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# Reset all three API responses to a complete successful run attempt.
fixture() {
  rm -rf "$work/case"
  mkdir "$work/case"
  for attempt in 1 2 3; do
    cp "$work/good.json" "$work/case/response-$attempt"
    : >"$work/case/error-$attempt"
    printf '0\n' >"$work/case/status-$attempt"
  done
}
# Make one API read fail after emitting plausible partial output.
api_failure() {
  local attempt="$1" error="$2"
  # A later-page failure may already have emitted plausible successful slots.
  cp "$work/good.json" "$work/case/response-$attempt"
  printf '%s\n' "$error" >"$work/case/error-$attempt"
  printf '1\n' >"$work/case/status-$attempt"
}
# Run the extracted CI observer with isolated fake API and backoff commands.
observe() {
  (
    cd "$work/case"
    export FIXTURE="$work/case" PATH="$work/bin:$PATH"
    export REPOSITORY=devantler-tech/fixture RUN_ID=123 RUN_ATTEMPT=2
    bash -e "$work/observer.sh"
  ) >"$work/output" 2>&1
}
# Require successful evidence and the expected number of API reads.
accepts() {
  local label="$1" attempts="$2"
  observe || fail "$label: $(cat "$work/output")"
  [[ "$(cat "$work/case/count")" == "$attempts" ]] || fail "$label used the wrong retry count"
  echo "ok: $label"
}
# Require rejected evidence and the expected number of API reads.
rejects() {
  local label="$1" attempts="$2"
  if observe; then fail "$label accepted invalid evidence"; fi
  [[ "$(cat "$work/case/count")" == "$attempts" ]] || fail "$label used the wrong retry count"
  echo "ok: $label fails closed"
}
# Mutate a successful API payload and prove it fails without retries.
invalid_response() {
  local label="$1" mutation="$2"
  fixture
  jq "$mutation" "$work/good.json" >"$work/case/response-1"
  rejects "$label" 1
}

fixture
accepts 'complete paginated successful slots' 1
fixture
api_failure 1 'gh: Server Error (HTTP 502)'
accepts 'transient API failure then complete success' 2
cmp "$work/good.json" "$work/case/jobs.json" || fail 'partial output survived the retry'
[[ "$(cat "$work/case/sleeps")" == 2 ]] || fail 'first retry lacks bounded backoff'

fixture
api_failure 1 'gh: Server Error (HTTP 500)'
api_failure 2 'gh: Service Unavailable (HTTP 503)'
accepts 'two transient failures then complete success' 3
[[ "$(cat "$work/case/sleeps")" == $'2\n4' ]] || fail 'retry backoff is not bounded'

fixture
for attempt in 1 2 3; do api_failure "$attempt" 'gh: Gateway Timeout (HTTP 504)'; done
rejects 'exhausted transient failures with plausible partial output' 3
[[ "$(cat "$work/case/sleeps")" == $'2\n4' ]] || fail 'exhaustion slept after the final attempt'

for error in 'gh: Unauthorized (HTTP 401)' 'gh: Forbidden (HTTP 403)' 'gh: Not Found (HTTP 404)' 'gh: Unprocessable Entity (HTTP 422)' 'gh: Too Many Requests (HTTP 429)' 'gh: authentication failed' 'unknown operational failure' $'gh: earlier upstream timeout (HTTP 503)\ngh: Forbidden (HTTP 403)'; do
  fixture
  api_failure 1 "$error"
  rejects "$error" 1
done

fixture
api_failure 1 'gh: Server Error (HTTP 502)'
jq '.[1].jobs |= .[1:]' "$work/good.json" >"$work/case/response-2"
rejects 'failed first response cannot fill a missing slot in the retry' 2

fixture
printf '[{"total_count":4,"jobs":' >"$work/case/response-1"
rejects 'truncated JSON' 1
fixture
printf '[]\n' >"$work/case/response-1"
cat "$work/good.json" >>"$work/case/response-1"
rejects 'multiple response documents' 1
invalid_response 'empty response' '[]'
invalid_response 'null page' '.[1] = null'
invalid_response 'missing jobs array' 'del(.[1].jobs)'
invalid_response 'missing total count' 'del(.[1].total_count)'
invalid_response 'inconsistent page counts' '.[1].total_count = 5'
invalid_response 'missing later page' '.[0:1]'
invalid_response 'extra uncounted job' '.[0].total_count = 3 | .[1].total_count = 3'
invalid_response 'duplicate job identity' '.[1].jobs[1].id = 1'
invalid_response 'string total count' 'map(.total_count = "4")'
invalid_response 'fractional total count' 'map(.total_count = 4.5)'
invalid_response 'zero job identity' '.[0].jobs[0].id = 0'
invalid_response 'missing job name' 'del(.[0].jobs[0].name)'
invalid_response 'different run' '.[0].jobs[0].run_id = 999'
invalid_response 'different attempt' '.[1].jobs[0].run_attempt = 1'
invalid_response 'unrelated job from a different attempt' '.[1].jobs[1].run_attempt = 1'
invalid_response 'missing attempt identity' 'del(.[0].jobs[0].run_attempt)'
invalid_response 'failed queue slot' '.[1].jobs[0].conclusion = "failure"'
invalid_response 'cancelled queue slot' '.[0].jobs[1].conclusion = "cancelled"'
invalid_response 'pending queue slot' '.[0].jobs[0].status = "queued" | .[0].jobs[0].conclusion = null'
invalid_response 'missing queue slot' '.[1].jobs[0].name = "Other job"'
invalid_response 'duplicate queue slot name' '.[1].jobs[0].name = "[Test] Enable Auto-Merge - Queue Slot 1"'
invalid_response 'unexpected fourth queue slot' '.[1].jobs[1].name = "[Test] Enable Auto-Merge - Queue Slot 4"'
invalid_response 'queue slot name with an extra suffix' '.[0].jobs[0].name += " (retry)"'
fixture
jq '.[1].jobs[1].status = "completed" | .[1].jobs[1].conclusion = "failure"' "$work/good.json" >"$work/case/response-1"
accepts 'unrelated job failure does not change the queue verdict' 1
