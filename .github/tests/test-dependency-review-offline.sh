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
cleanup() {
  [[ -z "$api_pid" ]] || kill "$api_pid" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

go build -o "$work/api" "$root/.github/tests/fixtures/offline-github-api.go"

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

stop_api() {
  kill "$api_pid"
  wait "$api_pid" || fail "the stand-in did not stop cleanly: $(cat "$work/api.log")"
  api_pid=''
}

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

accept() { # <scenario-file> — uses the current record
  REVIEW_OUTCOME="$(jq -r '.expect.outcome' "$1")" COMMENT_CONTENT="$(report "$1")" \
    bash "$helper" check "$1" "$work/requests.jsonl" "$work/blocked-hosts" >"$work/check.log" 2>&1 ||
    fail "$(basename "$1" .json): the reviewed conversation was rejected: $(cat "$work/check.log")"
}

# Run the check with a deliberate mistake; it must fail and name that mistake.
reject() { # <label> <diagnostic> <scenario-file> <record> <blocked-hosts> <outcome> <content>
  if REVIEW_OUTCOME="$6" COMMENT_CONTENT="$7" bash "$helper" check "$3" "$4" "$5" >"$work/check.log" 2>&1; then
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
stop_api

jq -cs '[.[] | [.method, .path, .authorized, .route, .status]]' "$work/requests.jsonl" >"$work/recorded"
jq -cn --arg listing "$listing" '[
  ["GET", $listing, false, -1, 401], ["GET", $listing, false, -1, 401], ["GET", $listing, false, -1, 401],
  ["GET", "/repos/offline/fixture/pulls/7", true, -1, 404], ["DELETE", $listing, true, -1, 404],
  ["GET", $listing, true, 2, 200], ["GET", $listing, true, 1, 200],
  ["PATCH", "/repos/offline/fixture/issues/comments/202", true, 3, 200],
  ["PATCH", "/repos/offline/fixture/issues/comments/202", true, 3, 200]]' >"$work/expected"
cmp -s "$work/recorded" "$work/expected" ||
  fail "the stand-in recorded something else: $(cat "$work/recorded")"
jq -es '.[5].query == {"per_page": ["100"]} and .[6].query == {"page": ["2"]} and
  .[0].body == null and .[7].body == {"body": "x"} and .[8].body == "not json"' "$work/requests.jsonl" >/dev/null ||
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

printf 'api.github.com\n' >"$work/reached"
reject 'a lookup of the live API' 'tried to reach hosts' "$created" "$good" "$work/reached" success "$(report "$created")"

jq 'del(.expect.outcome)' "$created" >"$work/no-expectation.json"
reject 'a scenario without an expected outcome' 'complete expectation' "$work/no-expectation.json" "$good" "$blocked" success "$(report "$created")"

jq '.expect.requests = []' "$created" >"$work/no-requests.json"
reject 'a scenario without a reviewed conversation' 'complete expectation' "$work/no-requests.json" "$good" "$blocked" success "$(report "$created")"

# A write of the wrong kind: the update scenario answered with a new comment.
jq '.expect.comment = "updated"' "$created" >"$work/wrong-kind.json"
reject 'a new comment where an update is expected' 'summary comment is not' "$work/wrong-kind.json" "$good" "$blocked" success "$(report "$created")"

# A scenario that expects no comment rejects any write, whatever its conversation says.
jq '.expect.comment = "none"' "$created" >"$work/no-comment.json"
reject 'a comment where none is expected' 'summary comment is not' "$work/no-comment.json" "$good" "$blocked" success "$(report "$created")"

# The enforcing scenario's report must name the advisory it blocked on.
start_api "$vulnerable"
replay "$vulnerable"
stop_api
jq -c 'if .method == "POST" then .body.body = "Offline replay report" else . end' "$work/requests.jsonl" >"$work/no-advisory.jsonl"
reject 'a report that omits the advisory' 'summary comment is not' "$vulnerable" "$work/no-advisory.jsonl" "$blocked" failure 'Offline replay report'
reject 'an enforcing review that passed' "finished with 'success'" "$vulnerable" "$work/requests.jsonl" "$blocked" success "$(report "$vulnerable")"

# The update must reach the existing summary through the later page.
start_api "$updated"
replay "$updated"
stop_api
jq -cs '[.[0], .[1], .[3]][]' "$work/requests.jsonl" >"$work/one-page.jsonl"
reject 'an update that skipped the later page' 'differ from the reviewed conversation' "$updated" "$work/one-page.jsonl" "$blocked" success "$(report "$updated")"

# A scenario served by the wrong conversation: comments off, yet the action wrote one.
reject 'a comment while comments are off' 'differ from the reviewed conversation' "$never" "$good" "$blocked" success "$(report "$never")"

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
})();
PROBE
start_api "$created"
: >"$work/preload-blocked"
env -i PATH="$PATH" FIXTURE_TOKEN="$token" NODE_OPTIONS="--require=$preload" \
  OFFLINE_GITHUB_API_URL="$address" OFFLINE_GITHUB_EVENT_NAME=pull_request \
  OFFLINE_GITHUB_EVENT_PATH="$root/.github/tests/dependency-review-offline/event.json" \
  OFFLINE_GITHUB_REPOSITORY=offline/fixture OFFLINE_BLOCKED_HOSTS_FILE="$work/preload-blocked" \
  GITHUB_API_URL=https://api.github.com GITHUB_EVENT_NAME=push GITHUB_REPOSITORY=devantler-tech/.github \
  node "$work/probe.cjs" >"$work/probe.log" 2>&1 || fail "the preloaded process failed: $(cat "$work/probe.log")"
stop_api
printf '%s %s/graphql pull_request %s offline/fixture\nfetch ENOTFOUND\nhttps ENOTFOUND\nloopback 200\n' \
  "$address" "$address" "$root/.github/tests/dependency-review-offline/event.json" >"$work/probe.expected"
cmp -s "$work/probe.log" "$work/probe.expected" ||
  fail "the preload did not redirect and isolate the process: $(cat "$work/probe.log")"
printf 'api.github.com\nuploads.github.com\n' >"$work/preload-blocked.expected"
cmp -s "$work/preload-blocked" "$work/preload-blocked.expected" ||
  fail "the preload did not record the refused hosts: $(cat "$work/preload-blocked")"

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
  OFFLINE_BLOCKED_HOSTS_FILE="$work/preload-blocked")
refuse_preload 'no stand-in address' 'OFFLINE_GITHUB_API_URL is not set' "${complete[@]:1}"
refuse_preload 'the live API address' 'must be the loopback stand-in' OFFLINE_GITHUB_API_URL=https://api.github.com "${complete[@]:1}"
refuse_preload 'a loopback look-alike host' 'must be the loopback stand-in' OFFLINE_GITHUB_API_URL=http://127.0.0.1:80.example.com "${complete[@]:1}"
refuse_preload 'no fixture event' 'OFFLINE_GITHUB_EVENT_PATH is not set' "${complete[@]:0:2}" "${complete[@]:3}"
refuse_preload 'no fixture repository' 'OFFLINE_GITHUB_REPOSITORY is not set' "${complete[@]:0:3}" "${complete[@]:4}"
refuse_preload 'no blocked-host record' 'OFFLINE_BLOCKED_HOSTS_FILE is not set' "${complete[@]:0:4}"

echo "PASS: offline stand-in, preload and conversation check — $scenario_count scenarios accepted, $controls mistakes rejected"
