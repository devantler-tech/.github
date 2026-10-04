#!/usr/bin/env bash
# The offline API stand-in, the environment preload and the conversation check behind the
# hosted dependency-review comment scenarios, exercised without the action itself.
#
# Every scenario's reviewed conversation is replayed against the real stand-in and must be
# accepted. Each deliberate mistake must then be rejected for its own reason, so a check
# that stopped looking cannot pass.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root/.github/tests/dependency-review-offline.sh"
scenarios="$root/.github/tests/dependency-review-offline/scenarios"
preload="$root/.github/tests/fixtures/offline-github-env.cjs"
token=offline-fixture-token
work="$(mktemp -d)"
api_pid=''
hosted_pid=''
# Stop the local fixture and remove its temporary evidence.
cleanup() {
  [[ -z "$api_pid" ]] || kill "$api_pid" >/dev/null 2>&1 || true
  [[ -z "$hosted_pid" ]] || kill "$hosted_pid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Report a violated offline replay invariant and stop.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

go build -o "$work/api" "$root/.github/tests/fixtures/offline-github-api/main.go"

# Start the exact scenario API and require its bounded readiness signal.
start_api() { # <scenario-file>
  rm -f "$work/address" "$work/requests.jsonl"
  : >"$work/requests.jsonl"
  "$work/api" -scenario "$1" -record "$work/requests.jsonl" -address-file "$work/address" \
    -token "$token" >"$work/api.log" 2>&1 &
  api_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "$work/address" ]] && break
    sleep 0.1
  done
  [[ -s "$work/address" ]] || fail "the stand-in did not start: $(cat "$work/api.log")"
  address="$(cat "$work/address")"
}

# Stop the API after collecting its request record.
stop_api() {
  kill "$api_pid"
  wait "$api_pid" || fail "the stand-in did not stop cleanly: $(cat "$work/api.log")"
  api_pid=''
}

# Replay one reviewed HTTP request and retain its response status.
request() { # <method> <url> <authorization> [json-body] -> status
  local arguments=(-sS --max-time 10 -o "$work/response" -D "$work/headers" -w '%{http_code}' -X "$1")
  [[ -z "$3" ]] || arguments+=(-H "Authorization: $3")
  [[ $# -lt 4 ]] || arguments+=(-H 'Content-Type: application/json' --data-binary "$4")
  curl "${arguments[@]}" "$2"
}

# The report a replayed write carries: the action's own output plus whatever the scenario
# requires the real report to name.
report() { # <scenario-file>
  printf 'Offline replay report %s' "$(jq -r '.expect["comment-includes"] // ""' "$1")"
}

# Send the scenario's reviewed conversation the way the action would.
replay() { # <scenario-file>
  local scenario="$1" count index method path query body
  count="$(jq '.expect.requests | length' "$scenario")"
  body="$(jq -cn --arg body "$(report "$scenario")" '{body: $body}')"
  for ((index = 0; index < count; index++)); do
    method="$(jq -r --argjson index "$index" '.expect.requests[$index].method' "$scenario")"
    path="$(jq -r --argjson index "$index" '.expect.requests[$index].path' "$scenario")"
    query="$(jq -r --argjson index "$index" '
      .expect.requests[$index].query // {} | to_entries | map("\(.key)=\(.value | @uri)") | join("&")' "$scenario")"
    if [[ "$method" == GET ]]; then
      request GET "$address$path${query:+?$query}" "token $token" >/dev/null
    else
      request "$method" "$address$path${query:+?$query}" "token $token" "$body" >/dev/null
    fi
  done
}

# The hosts the scenario expects the action to be refused, one per line.
refused_hosts() { # <scenario-file> <output-file>
  jq -r '.expect["blocked-hosts"][]' "$1" >"$2"
}

# What the action would print while raising the errors and warnings the scenario expects,
# between ordinary output.
raised() { # <scenario-file> <output-file>
  {
    echo 'Offline replay output'
    jq -r '.expect.annotations // [] | .[] | "::\(.level)::\(.includes) (offline replay)"' "$1"
    echo '  ::error::indented text is ordinary output'
  } >"$2"
}

# Require the production verifier to accept a complete reviewed conversation.
accept() { # <scenario-file> — uses the current record
  refused_hosts "$1" "$work/refused-hosts"
  raised "$1" "$work/raised.log"
  REVIEW_OUTCOME="$(jq -r '.expect.outcome' "$1")" COMMENT_CONTENT="$(report "$1")" \
    bash "$helper" check "$1" "$work/requests.jsonl" "$work/refused-hosts" "$work/raised.log" >"$work/check.log" 2>&1 ||
    fail "$(basename "$1" .json): the reviewed conversation was rejected: $(cat "$work/check.log")"
}

# Run the check with a deliberate mistake; it must fail and name that mistake. Without an
# action log of its own, the action raised exactly what the scenario expects.
reject() { # <label> <diagnostic> <scenario-file> <record> <blocked-hosts> <outcome> <content> [action-log]
  local log="${8:-$work/raised.log}"
  [[ $# -ge 8 ]] || raised "$3" "$log"
  if REVIEW_OUTCOME="$6" COMMENT_CONTENT="$7" bash "$helper" check "$3" "$4" "$5" "$log" >"$work/check.log" 2>&1; then
    fail "accepted $1"
  fi
  grep -qF "$2" "$work/check.log" || fail "$1 was rejected for the wrong reason: $(cat "$work/check.log")"
  controls=$((controls + 1))
}

# ── The stand-in itself ────────────────────────────────────────────────────────
: >"$work/blocked-hosts"
start_api "$scenarios/comment-updated.json"
[[ "$address" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || fail "the stand-in must listen on loopback only: $address"
listing=/repos/offline/fixture/issues/7/comments

[[ "$(request GET "$address$listing" '')" == 401 ]] || fail 'a request without a token was served'
[[ "$(request GET "$address$listing" 'token live-token')" == 401 ]] || fail 'a request with another token was served'
[[ "$(request GET "$address$listing" "basic $token")" == 401 ]] || fail 'a request with another scheme was served'
[[ "$(request GET "$address/repos/offline/fixture/pulls/7" "token $token")" == 404 ]] ||
  fail 'a request without a route was served'
[[ "$(request DELETE "$address$listing" "token $token")" == 404 ]] ||
  fail 'a method without a route was served'

[[ "$(request GET "$address$listing?per_page=100" "Bearer $token")" == 200 ]] || fail 'the first page was not served'
jq -e 'length == 1 and .[0].id == 201' "$work/response" >/dev/null || fail 'the first page has the wrong content'
grep -qiF "link: <$address$listing?page=2>; rel=\"next\"" "$work/headers" ||
  fail 'the first page does not link to the next one on the stand-in'
[[ "$(request GET "$address$listing?page=2" "token $token")" == 200 ]] || fail 'the second page was not served'
jq -e 'length == 1 and .[0].id == 202' "$work/response" >/dev/null || fail 'the query-specific route did not win'
[[ "$(request PATCH "$address/repos/offline/fixture/issues/comments/202" "token $token" '{"body":"x"}')" == 200 ]] ||
  fail 'the update route was not served'
[[ "$(request PATCH "$address/repos/offline/fixture/issues/comments/202" "token $token" 'not json')" == 200 ]] ||
  fail 'a non-JSON body was not served'
head -c 1049600 /dev/zero | tr '\0' 'a' >"$work/oversized"
[[ "$(request PATCH "$address/repos/offline/fixture/issues/comments/202" "token $token" "@$work/oversized")" == 413 ]] ||
  fail 'a body the stand-in cannot record whole was served'
stop_api

jq -cs '[.[] | [.method, .path, .authorized, .route, .status]]' "$work/requests.jsonl" >"$work/recorded"
jq -cn --arg listing "$listing" '[
  ["GET", $listing, false, -1, 401], ["GET", $listing, false, -1, 401], ["GET", $listing, false, -1, 401],
  ["GET", "/repos/offline/fixture/pulls/7", true, -1, 404], ["DELETE", $listing, true, -1, 404],
  ["GET", $listing, true, 2, 200], ["GET", $listing, true, 1, 200],
  ["PATCH", "/repos/offline/fixture/issues/comments/202", true, 3, 200],
  ["PATCH", "/repos/offline/fixture/issues/comments/202", true, 3, 200],
  ["PATCH", "/repos/offline/fixture/issues/comments/202", true, -1, 413]]' >"$work/expected"
cmp -s "$work/recorded" "$work/expected" ||
  fail "the stand-in recorded something else: $(cat "$work/recorded")"
jq -es '.[5].query == {"per_page": ["100"]} and .[6].query == {"page": ["2"]} and
  .[0].body == null and .[7].body == {"body": "x"} and .[8].body == "not json" and
  .[9].body == null' "$work/requests.jsonl" >/dev/null ||
  fail 'the stand-in recorded the wrong query or body'
if grep -qF -e live-token -e "$token" "$work/requests.jsonl"; then fail 'the record holds a token'; fi

# A stand-in that cannot serve exactly what was reviewed must stop before it listens. It
# runs in the background with a bounded wait, so one that starts anyway fails this test
# instead of hanging it.
refuse_start() { # <label> <stand-in arguments...>
  local label="$1"
  shift
  rm -f "$work/bad-address"
  "$work/api" "$@" -record "$work/bad.jsonl" -address-file "$work/bad-address" >"$work/bad.log" 2>&1 &
  api_pid=$!
  for _ in $(seq 1 100); do
    kill -0 "$api_pid" 2>/dev/null || break
    [[ ! -e "$work/bad-address" ]] || break
    sleep 0.1
  done
  if kill -0 "$api_pid" 2>/dev/null; then fail "the stand-in started with $label"; fi
  if wait "$api_pid"; then fail "the stand-in exited cleanly with $label"; fi
  api_pid=''
  [[ ! -e "$work/bad-address" ]] || fail "the stand-in published an address with $label"
  controls=$((controls + 1))
}
# Require malformed scenario admission to fail for the expected reason.
bad_scenario() { # <label> <jq-mutation>
  jq "$2" "$scenarios/comment-created.json" >"$work/bad.json"
  refuse_start "$1" -scenario "$work/bad.json" -token "$token"
}
controls=0
bad_scenario 'a scenario without routes' 'del(.routes)'
bad_scenario 'an empty route list' '.routes = []'
bad_scenario 'a misspelt route key' '.routes[0].querry = {"page": "2"}'
bad_scenario 'a lower-case method' '.routes[0].method = "get"'
bad_scenario 'a relative path' '.routes[0].path = "repos/offline/fixture"'
bad_scenario 'a missing status' 'del(.routes[0].status)'
refuse_start 'no fixture token' -scenario "$scenarios/comment-created.json"
refuse_start 'a missing scenario file' -scenario "$work/absent.json" -token "$token"

# ── Every scenario's reviewed conversation is accepted ────────────────────────
scenario_count=0
for scenario in "$scenarios"/*.json; do
  start_api "$scenario"
  replay "$scenario"
  stop_api
  accept "$scenario"
  scenario_count=$((scenario_count + 1))
done
[[ "$scenario_count" -gt 0 ]] || fail 'no scenario was found'

# ── Each mistake is rejected for its own reason ───────────────────────────────
created="$scenarios/comment-created.json"
updated="$scenarios/comment-updated.json"
vulnerable="$scenarios/on-failure-vulnerable.json"
never="$scenarios/comment-never.json"
good="$work/good.jsonl"
blocked="$work/blocked-hosts"

start_api "$created"
replay "$created"
stop_api
cp "$work/requests.jsonl" "$good"
accept "$created"

: >"$work/empty.jsonl"
reject 'an action that sent nothing' 'sent no request' "$created" "$work/empty.jsonl" "$blocked" success "$(report "$created")"

{ cat "$good"; echo '{"method":"GET"'; } >"$work/truncated.jsonl"
reject 'a truncated record' 'record is unreadable' "$created" "$work/truncated.jsonl" "$blocked" success "$(report "$created")"

{ cat "$good"; echo '"a string"'; } >"$work/shape.jsonl"
reject 'a malformed record entry' 'record is unreadable' "$created" "$work/shape.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .method == "POST" then .authorized = false else . end' "$good" >"$work/unauthorized.jsonl"
reject 'a write without the fixture token' 'did not carry the fixture token' "$created" "$work/unauthorized.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .method == "POST" then .route = -1 else . end' "$good" >"$work/unmatched.jsonl"
reject 'a request no route describes' 'does not describe: POST' "$created" "$work/unmatched.jsonl" "$blocked" success "$(report "$created")"

jq -c 'select(.method != "POST")' "$good" >"$work/suppressed.jsonl"
reject 'a suppressed comment' 'differ from the reviewed conversation' "$created" "$work/suppressed.jsonl" "$blocked" success "$(report "$created")"

{ cat "$good"; tail -n 1 "$good"; } >"$work/doubled.jsonl"
reject 'a comment posted twice' 'differ from the reviewed conversation' "$created" "$work/doubled.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .method == "POST" then .path = "/repos/offline/fixture/issues/8/comments" else . end' "$good" >"$work/other-pr.jsonl"
reject 'a comment on another pull request' 'differ from the reviewed conversation' "$created" "$work/other-pr.jsonl" "$blocked" success "$(report "$created")"

jq -cs '[.[1], .[0], .[2]][]' "$good" >"$work/reordered.jsonl"
reject 'a comment listed before the review' 'differ from the reviewed conversation' "$created" "$work/reordered.jsonl" "$blocked" success "$(report "$created")"

reject 'a failed action' "finished with 'failure'" "$created" "$good" "$blocked" failure "$(report "$created")"
reject 'a skipped action' "finished with ''" "$created" "$good" "$blocked" '' "$(report "$created")"

reject 'a comment without the action report' 'summary comment is not' "$created" "$good" "$blocked" success 'Another report'
reject 'an empty action report' 'summary comment is not' "$created" "$good" "$blocked" success ''

jq -c 'if .method == "POST" then .status = 403 else . end' "$good" >"$work/refused.jsonl"
reject 'a refused comment' 'summary comment is not' "$created" "$work/refused.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .method == "POST" then .body = null else . end' "$good" >"$work/no-body.jsonl"
reject 'a comment without a body' 'summary comment is not' "$created" "$work/no-body.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .path | contains("/compare/") then .query = {"per_page": ["100"]} else . end' "$good" >"$work/other-query.jsonl"
reject 'a read with another page size' 'differ from the reviewed conversation' "$created" "$work/other-query.jsonl" "$blocked" success "$(report "$created")"

jq -c 'if .method == "POST" then .query = {"extra": ["1"]} else . end' "$good" >"$work/extra-query.jsonl"
reject 'a write with an unreviewed query' 'differ from the reviewed conversation' "$created" "$work/extra-query.jsonl" "$blocked" success "$(report "$created")"

printf 'api.github.com\n' >"$work/reached"
reject 'a lookup of the live API' 'could not resolve differ' "$created" "$good" "$work/reached" success "$(report "$created")"

printf '::warning::Unable to write summary to pull-request.\n' >"$work/warned.log"
reject 'a warning from a review that should raise none' 'errors and warnings the action raised differ' "$created" "$good" "$blocked" success "$(report "$created")" "$work/warned.log"

printf '::error title=Review::Dependency review failed\n' >"$work/errored.log"
reject 'an error with properties from a review that should raise none' 'errors and warnings the action raised differ' "$created" "$good" "$blocked" success "$(report "$created")" "$work/errored.log"

reject 'a missing action log' 'action log is unreadable' "$created" "$good" "$blocked" success "$(report "$created")" "$work/absent.log"

jq 'del(.expect.annotations)' "$created" >"$work/no-annotations.json"
reject 'a scenario without expected errors and warnings' 'complete expectation' "$work/no-annotations.json" "$good" "$blocked" success "$(report "$created")"

jq '.expect.annotations = [{"level": "notice", "includes": "x"}]' "$created" >"$work/bad-level.json"
reject 'a scenario with an unknown annotation level' 'complete expectation' "$work/bad-level.json" "$good" "$blocked" success "$(report "$created")"

jq '.expect.annotations = [{"level": "warning", "includes": ""}]' "$created" >"$work/any-warning.json"
reject 'a scenario that accepts any warning' 'complete expectation' "$work/any-warning.json" "$good" "$blocked" success "$(report "$created")"

jq 'del(.expect.outcome)' "$created" >"$work/no-expectation.json"
reject 'a scenario without an expected outcome' 'complete expectation' "$work/no-expectation.json" "$good" "$blocked" success "$(report "$created")"

jq '.expect.requests = []' "$created" >"$work/no-requests.json"
reject 'a scenario without a reviewed conversation' 'complete expectation' "$work/no-requests.json" "$good" "$blocked" success "$(report "$created")"

jq 'del(.expect.requests[0].query)' "$created" >"$work/no-query.json"
reject 'a reviewed request without its query' 'complete expectation' "$work/no-query.json" "$good" "$blocked" success "$(report "$created")"

jq 'del(.inputs["warn-only"])' "$created" >"$work/no-input.json"
reject 'a scenario that leaves an input to its default' 'action inputs' "$work/no-input.json" "$good" "$blocked" success "$(report "$created")"

jq '.inputs["fail-on-severity"] = "low"' "$created" >"$work/extra-input.json"
reject 'a scenario with an input the job does not pass' 'action inputs' "$work/extra-input.json" "$good" "$blocked" success "$(report "$created")"

jq '.inputs["warn-only"] = true' "$created" >"$work/typed-input.json"
reject 'a scenario with a non-string input' 'action inputs' "$work/typed-input.json" "$good" "$blocked" success "$(report "$created")"

# A write of the wrong kind: the update scenario answered with a new comment.
jq '.expect.comment = "updated"' "$created" >"$work/wrong-kind.json"
reject 'a new comment where an update is expected' 'summary comment is not' "$work/wrong-kind.json" "$good" "$blocked" success "$(report "$created")"

# A scenario that expects no comment rejects any write, whatever its conversation says.
jq '.expect.comment = "none"' "$created" >"$work/no-comment.json"
reject 'a comment where none is expected' 'summary comment is not' "$work/no-comment.json" "$good" "$blocked" success "$(report "$created")"

# The enforcing scenario's report must name the advisory it blocked on, which sits on the
# later page of changes, and its refused scorecard lookup is part of what was reviewed.
start_api "$vulnerable"
replay "$vulnerable"
stop_api
refused_hosts "$vulnerable" "$work/scorecard"
[[ -s "$work/scorecard" ]] || fail 'the enforcing scenario no longer expects a refused lookup'
jq -c 'if .method == "POST" then .body.body = "Offline replay report" else . end' "$work/requests.jsonl" >"$work/no-advisory.jsonl"
reject 'a report that omits the advisory' 'summary comment is not' "$vulnerable" "$work/no-advisory.jsonl" "$work/scorecard" failure 'Offline replay report'
reject 'an enforcing review that passed' "finished with 'success'" "$vulnerable" "$work/requests.jsonl" "$work/scorecard" success "$(report "$vulnerable")"
reject 'a lookup that was not refused' 'could not resolve differ' "$vulnerable" "$work/requests.jsonl" "$blocked" failure "$(report "$vulnerable")"
jq -cs '[.[0], .[2], .[3]][]' "$work/requests.jsonl" >"$work/first-page-only.jsonl"
reject 'a review that skipped the later page of changes' 'differ from the reviewed conversation' "$vulnerable" "$work/first-page-only.jsonl" "$work/scorecard" failure "$(report "$vulnerable")"

# The update must reach the existing summary through the later page.
start_api "$updated"
replay "$updated"
stop_api
jq -cs '[.[0], .[1], .[3]][]' "$work/requests.jsonl" >"$work/one-page.jsonl"
reject 'an update that skipped the later page' 'differ from the reviewed conversation' "$updated" "$work/one-page.jsonl" "$blocked" success "$(report "$updated")"

# A failed read is never a posted summary, and it is never silent. Where a summary is
# expected, the conversation of each failed read is rejected; and in its own scenario the
# action must raise exactly the reviewed error or warning.
: >"$work/silent.log"
for failed in "$scenarios/compare-forbidden.json" "$scenarios/comments-unreadable.json" "$scenarios/comment-rejected.json"; do
  name="$(basename "$failed" .json)"
  start_api "$failed"
  replay "$failed"
  stop_api
  cp "$work/requests.jsonl" "$work/failed.jsonl"
  # The rejected write has the reviewed requests of a created summary; only its answer differs.
  claimed='differ from the reviewed conversation'
  [[ "$name" != comment-rejected ]] || claimed='summary comment is not'
  reject "a summary claimed from the $name conversation" "$claimed" "$created" "$work/failed.jsonl" "$blocked" success "$(report "$created")"
  reject "a silent $name" 'errors and warnings the action raised differ' "$failed" "$work/failed.jsonl" "$blocked" "$(jq -r '.expect.outcome' "$failed")" "$(report "$failed")" "$work/silent.log"
done

warned="$scenarios/on-failure-warned.json"
start_api "$warned"
replay "$warned"
stop_api
refused_hosts "$warned" "$work/scorecard"
printf '::error::Dependency review detected vulnerable packages.\n' >"$work/escalated.log"
reject 'an error where a warning is expected' 'errors and warnings the action raised differ' "$warned" "$work/requests.jsonl" "$work/scorecard" success "$(report "$warned")" "$work/escalated.log"
printf '::warning::Something else went wrong.\n' >"$work/other-warning.log"
reject 'another warning than the reviewed one' 'errors and warnings the action raised differ' "$warned" "$work/requests.jsonl" "$work/scorecard" success "$(report "$warned")" "$work/other-warning.log"
raised "$warned" "$work/twice.log"
printf '::warning::Unable to write summary to pull-request.\n' >>"$work/twice.log"
reject 'a second warning beside the reviewed one' 'errors and warnings the action raised differ' "$warned" "$work/requests.jsonl" "$work/scorecard" success "$(report "$warned")" "$work/twice.log"

# A scenario served by the wrong conversation: comments off, yet the action wrote one.
reject 'a comment while comments are off' 'differ from the reviewed conversation' "$never" "$good" "$blocked" success "$(report "$never")"

# ── The hosted job's two steps, end to end ────────────────────────────────────
export RUNNER_TEMP="$work/runner"
mkdir "$RUNNER_TEMP"
hosted="$RUNNER_TEMP/dependency-review-offline"
# Exercise the production hosted-start helper with a controlled runner environment.
hosted_start() { # <scenario>
  : >"$work/output"
  GITHUB_OUTPUT="$work/output" bash "$helper" start "$1" >"$work/start.log" 2>&1 ||
    fail "the hosted start step failed: $(cat "$work/start.log")"
  hosted_pid="$(cat "$hosted/pid")"
  address="$(sed -n 's/^api-url=//p' "$work/output")"
}
hosted_start comment-updated
printf 'api-url=%s\nblocked-hosts-file=%s\naction-log-file=%s\ncomment-summary-in-pr=always\nwarn-only=true\n' \
  "$address" "$hosted/blocked-hosts" "$hosted/action.log" >"$work/output.expected"
cmp -s "$work/output" "$work/output.expected" || fail "the start step handed over the wrong outputs: $(cat "$work/output")"
replay "$updated"
REVIEW_OUTCOME=success COMMENT_CONTENT="$(report "$updated")" bash "$helper" verify comment-updated >"$work/verify.log" 2>&1 ||
  fail "the hosted verify step rejected the reviewed conversation: $(cat "$work/verify.log")"
grep -qF 'PASS: comment-updated — 4 recorded requests' "$work/verify.log" || fail 'the verify step did not report the conversation'
grep -qF '"method":"PATCH"' "$work/verify.log" || fail 'the verify step did not print the recorded requests'
if kill -0 "$hosted_pid" 2>/dev/null; then fail 'the verify step left the stand-in running'; fi
hosted_pid=''

# What the action raised reaches the verify step through the action log, and is printed
# indented so the runner does not raise it again.
hosted_start comment-rejected
replay "$scenarios/comment-rejected.json"
raised "$scenarios/comment-rejected.json" "$hosted/action.log"
REVIEW_OUTCOME=success COMMENT_CONTENT="$(report "$scenarios/comment-rejected.json")" \
  bash "$helper" verify comment-rejected >"$work/verify.log" 2>&1 ||
  fail "the hosted verify step rejected the reviewed warning: $(cat "$work/verify.log")"
grep -qxF '  ::warning::Unable to write summary to pull-request (offline replay)' "$work/verify.log" ||
  fail 'the verify step did not print the raised warning indented'
if grep -qE '^::(error|warning)' "$work/verify.log"; then fail 'the verify step raised an annotation of its own'; fi
hosted_pid=''

# Require a deliberately unsafe CI step to fail the boundary guard.
reject_step() { # <label> <diagnostic> <step> <scenario>
  if GITHUB_OUTPUT="$work/output" REVIEW_OUTCOME=success COMMENT_CONTENT=report \
    bash "$helper" "$3" "$4" >"$work/step.log" 2>&1; then
    fail "the $3 step accepted $1"
  fi
  grep -qF "$2" "$work/step.log" || fail "$1 was refused for the wrong reason: $(cat "$work/step.log")"
  controls=$((controls + 1))
}
reject_step 'an unknown scenario' "unknown scenario 'absent'" start absent
reject_step 'a scenario outside the reviewed directory' 'unknown scenario' start ../event
reject_step 'an unknown scenario' "unknown scenario 'absent'" verify absent

# The action talked to nothing: the conversation it should have had is missing.
hosted_start comment-created
reject_step 'an action that never reached the stand-in' 'sent no request' verify comment-created
if kill -0 "$hosted_pid" 2>/dev/null; then fail 'a failed verify step left the stand-in running'; fi

# A stand-in that died mid-run cannot vouch for the conversation.
hosted_start comment-created
kill "$hosted_pid"
for _ in $(seq 1 100); do
  kill -0 "$hosted_pid" 2>/dev/null || break
  sleep 0.1
done
reject_step 'a stand-in that exited early' 'exited before the action finished' verify comment-created
hosted_pid=''

# ── The preload ────────────────────────────────────────────────────────────────
cat >"$work/probe.cjs" <<'PROBE'
const https = require('node:https');
(async () => {
  console.log([process.env.GITHUB_API_URL, process.env.GITHUB_GRAPHQL_URL, process.env.GITHUB_EVENT_NAME,
    process.env.GITHUB_EVENT_PATH, process.env.GITHUB_REPOSITORY].join(' '));
  try { await fetch('https://api.github.com/zen'); console.log('fetch reached'); } catch (error) { console.log(`fetch ${error.cause && error.cause.code}`); }
  await new Promise((resolve) => {
    https.get('https://uploads.github.com/', () => { console.log('https reached'); resolve(); })
      .on('error', (error) => { console.log(`https ${error.code}`); resolve(); });
  });
  const response = await fetch(`${process.env.GITHUB_API_URL}/repos/offline/fixture/issues/7/comments`,
    { headers: { authorization: `token ${process.env.FIXTURE_TOKEN}` } });
  console.log(`loopback ${response.status}`);
  process.stdout.write('::warning::raised on standard output\n');
  process.stderr.write(Buffer.from('::error::raised on standard error\n'));
})();
PROBE
start_api "$created"
: >"$work/preload-blocked"
: >"$work/preload-action.log"
env -i PATH="$PATH" FIXTURE_TOKEN="$token" NODE_OPTIONS="--require=$preload" \
  OFFLINE_GITHUB_API_URL="$address" OFFLINE_GITHUB_EVENT_NAME=pull_request \
  OFFLINE_GITHUB_EVENT_PATH="$root/.github/tests/dependency-review-offline/event.json" \
  OFFLINE_GITHUB_REPOSITORY=offline/fixture OFFLINE_BLOCKED_HOSTS_FILE="$work/preload-blocked" \
  OFFLINE_ACTION_LOG_FILE="$work/preload-action.log" \
  GITHUB_API_URL=https://api.github.com GITHUB_EVENT_NAME=push GITHUB_REPOSITORY=devantler-tech/.github \
  node "$work/probe.cjs" >"$work/probe.log" 2>&1 || fail "the preloaded process failed: $(cat "$work/probe.log")"
stop_api
printf '%s %s/graphql pull_request %s offline/fixture\nfetch ENOTFOUND\nhttps ENOTFOUND\nloopback 200\n%s\n%s\n' \
  "$address" "$address" "$root/.github/tests/dependency-review-offline/event.json" \
  '::warning::raised on standard output' '::error::raised on standard error' >"$work/probe.expected"
cmp -s "$work/probe.log" "$work/probe.expected" ||
  fail "the preload did not redirect and isolate the process: $(cat "$work/probe.log")"
cmp -s "$work/preload-action.log" "$work/probe.expected" ||
  fail "the preload did not copy what the process printed: $(cat "$work/preload-action.log")"
printf 'api.github.com\nuploads.github.com\n' >"$work/preload-blocked.expected"
cmp -s "$work/preload-blocked" "$work/preload-blocked.expected" ||
  fail "the preload did not record the refused hosts: $(cat "$work/preload-blocked")"

# Require the preload to refuse a forbidden environment or network operation.
refuse_preload() { # <label> <diagnostic> <env assignments...>
  local label="$1" diagnostic="$2"
  shift 2
  if env -i PATH="$PATH" NODE_OPTIONS="--require=$preload" "$@" node -e 'console.log("started")' >"$work/preload.log" 2>&1; then
    fail "the preload let the action start with $label"
  fi
  if grep -qF started "$work/preload.log"; then fail "the action ran with $label"; fi
  grep -qF "$diagnostic" "$work/preload.log" || fail "$label was refused for the wrong reason: $(cat "$work/preload.log")"
  controls=$((controls + 1))
}
complete=(OFFLINE_GITHUB_API_URL=http://127.0.0.1:9 OFFLINE_GITHUB_EVENT_NAME=pull_request
  OFFLINE_GITHUB_EVENT_PATH=/dev/null OFFLINE_GITHUB_REPOSITORY=offline/fixture
  OFFLINE_BLOCKED_HOSTS_FILE="$work/preload-blocked" OFFLINE_ACTION_LOG_FILE="$work/preload-action.log")
refuse_preload 'no stand-in address' 'OFFLINE_GITHUB_API_URL is not set' "${complete[@]:1}"
refuse_preload 'the live API address' 'must be the loopback stand-in' OFFLINE_GITHUB_API_URL=https://api.github.com "${complete[@]:1}"
refuse_preload 'a loopback look-alike host' 'must be the loopback stand-in' OFFLINE_GITHUB_API_URL=http://127.0.0.1:80.example.com "${complete[@]:1}"
refuse_preload 'no fixture event' 'OFFLINE_GITHUB_EVENT_PATH is not set' "${complete[@]:0:2}" "${complete[@]:3}"
refuse_preload 'no fixture repository' 'OFFLINE_GITHUB_REPOSITORY is not set' "${complete[@]:0:3}" "${complete[@]:4}"
refuse_preload 'no blocked-host record' 'OFFLINE_BLOCKED_HOSTS_FILE is not set' "${complete[@]:0:4}" "${complete[@]:5}"
refuse_preload 'no action log' 'OFFLINE_ACTION_LOG_FILE is not set' "${complete[@]:0:5}"

echo "PASS: offline stand-in, preload and conversation check — $scenario_count scenarios accepted, $controls mistakes rejected"
