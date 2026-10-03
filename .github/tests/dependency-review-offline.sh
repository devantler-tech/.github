#!/usr/bin/env bash
# Run the dependency-review comment scenarios against the offline API stand-in.
#
#   start  <scenario>   build and start the stand-in, and hand its address and the
#                       scenario's action inputs to the job
#   verify <scenario>   stop the stand-in, print what it recorded, and check it
#   check  <scenario-file> <request-record> <blocked-hosts-file>
#                       the check on its own; reads REVIEW_OUTCOME and COMMENT_CONTENT
#
# The action under test receives only the fixture token below. A scenario file holds the
# reviewed responses, the action inputs, and the complete conversation the action must
# have with the stand-in; see .github/tests/dependency-review-offline/scenarios/.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scenarios="$root/.github/tests/dependency-review-offline/scenarios"
token=offline-fixture-token

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

scenario_file() {
  [[ "$1" =~ ^[a-z0-9-]+$ && -f "$scenarios/$1.json" ]] || fail "unknown scenario '$1'"
  printf '%s\n' "$scenarios/$1.json"
}

# The job passes exactly two inputs to the action, so a scenario that left one out would run
# with the action's default instead; and a request is reviewed only with its whole query.
validate() { # <scenario-file>
  jq -e '
    (.inputs | type) == "object" and (.inputs | keys) == ["comment-summary-in-pr", "warn-only"] and
    all(.inputs[]; type == "string" and test("^[a-z-]+$")) and
    (.expect | type) == "object" and
    (.expect.outcome == "success" or .expect.outcome == "failure") and
    (.expect.comment | IN("created", "updated", "rejected", "none")) and
    (.expect.requests | type) == "array" and (.expect.requests | length) > 0 and
    all(.expect.requests[]; (.method | type) == "string" and (.path | type) == "string" and
      (.query | type) == "object" and all(.query[]; type == "string")) and
    (.expect["blocked-hosts"] | type) == "array"' "$1" >/dev/null ||
    fail "the scenario does not state its action inputs and a complete expectation"
}

check() {
  local scenario="$1" record="$2" blocked="$3" requests expected got unmatched
  local outcome="${REVIEW_OUTCOME:-}" content="${COMMENT_CONTENT:-}"

  validate "$scenario"

  requests="$(jq -cs '
    if all(.[]; type == "object" and (.method | type) == "string" and (.path | type) == "string" and
      (.query | type) == "object" and (.authorized | type) == "boolean" and
      (.route | type) == "number" and (.status | type) == "number")
    then . else error("malformed entry") end' "$record" 2>/dev/null)" ||
    fail "the request record is unreadable"
  [[ "$(jq 'length' <<<"$requests")" != 0 ]] ||
    fail "the action sent no request to the stand-in"
  jq -e 'all(.[]; .authorized)' <<<"$requests" >/dev/null ||
    fail "a request did not carry the fixture token"
  unmatched="$(jq -r '[.[] | select(.route < 0) | "\(.method) \(.path)"] | join(", ")' <<<"$requests")"
  [[ -z "$unmatched" ]] ||
    fail "the action sent a request the scenario does not describe: $unmatched"

  # Method, path and the whole query of every request, in order: nothing more, nothing less.
  expected="$(jq -cS '[.expect.requests[] | {method, path, query: (.query | map_values([.]))}]' "$scenario")"
  got="$(jq -cS '[.[] | {method, path, query}]' <<<"$requests")"
  [[ "$got" == "$expected" ]] ||
    fail "the recorded requests differ from the reviewed conversation
  expected: $expected
  recorded: $got"

  [[ "$outcome" == "$(jq -r '.expect.outcome' "$scenario")" ]] ||
    fail "the action finished with '$outcome'; the scenario expects '$(jq -r '.expect.outcome' "$scenario")'"

  COMMENT_CONTENT="$content" jq -e --slurpfile scenario "$scenario" '
    $scenario[0].expect as $expect |
    [.[] | select(.method != "GET" and .method != "HEAD")] as $writes |
    def carries_summary:
      (env.COMMENT_CONTENT | length) > 0 and ((.body.body? // "") | contains(env.COMMENT_CONTENT)) and
      ((.body.body? // "") | contains($expect["comment-includes"] // ""));
    if $expect.comment == "none" then ($writes | length) == 0
    elif ($writes | length) != 1 then false
    elif $expect.comment == "created" then
      $writes[0] | .method == "POST" and .status == 201 and carries_summary
    elif $expect.comment == "rejected" then
      $writes[0] | .method == "POST" and .status == 403 and carries_summary
    else
      $writes[0] | .method == "PATCH" and .status == 200 and carries_summary
    end' <<<"$requests" >/dev/null ||
    fail "the summary comment is not '$(jq -r '.expect.comment' "$scenario")' with the action's own report"

  [[ "$(jq -Rcn '[inputs | select(length > 0)] | unique' "$blocked")" == "$(jq -c '.expect["blocked-hosts"] | unique' "$scenario")" ]] ||
    fail "the hosts the action could not resolve differ from the scenario's: $(jq -Rcn '[inputs | select(length > 0)] | unique' "$blocked")"

  echo "PASS: $(basename "$scenario" .json) — $(jq 'length' <<<"$requests") recorded requests match the reviewed conversation"
}

case "${1:-}" in
start)
  [[ $# == 2 ]] || fail "usage: dependency-review-offline.sh start <scenario>"
  scenario="$(scenario_file "$2")"
  validate "$scenario"
  work="${RUNNER_TEMP:?}/dependency-review-offline"
  rm -rf "$work"
  mkdir -p "$work"
  go build -o "$work/api" "$root/.github/tests/fixtures/offline-github-api/main.go"
  : >"$work/requests.jsonl"
  : >"$work/blocked-hosts"
  nohup "$work/api" -scenario "$scenario" -record "$work/requests.jsonl" \
    -address-file "$work/address" -token "$token" </dev/null >"$work/api.log" 2>&1 &
  echo "$!" >"$work/pid"
  for _ in $(seq 1 100); do
    [[ -s "$work/address" ]] && break
    sleep 0.1
  done
  [[ -s "$work/address" ]] || {
    cat "$work/api.log" >&2
    fail "the offline stand-in did not start"
  }
  {
    echo "api-url=$(cat "$work/address")"
    echo "blocked-hosts-file=$work/blocked-hosts"
    jq -r '.inputs | to_entries[] | "\(.key)=\(.value)"' "$scenario"
  } >>"${GITHUB_OUTPUT:?}"
  echo "Offline stand-in for '$2' listens on $(cat "$work/address")"
  ;;
verify)
  [[ $# == 2 ]] || fail "usage: dependency-review-offline.sh verify <scenario>"
  scenario="$(scenario_file "$2")"
  work="${RUNNER_TEMP:?}/dependency-review-offline"
  pid="$(cat "$work/pid")"
  kill -0 "$pid" 2>/dev/null || {
    cat "$work/api.log" >&2
    fail "the offline stand-in exited before the action finished"
  }
  kill "$pid"
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then fail "the offline stand-in did not stop"; fi
  echo "::group::Requests the action sent to the stand-in"
  cat "$work/requests.jsonl"
  echo "::endgroup::"
  echo "::group::Hosts the action could not resolve"
  cat "$work/blocked-hosts"
  echo "::endgroup::"
  echo "::group::Action outcome and comment content"
  printf 'outcome: %s\n%s\n' "${REVIEW_OUTCOME:-}" "${COMMENT_CONTENT:-}"
  echo "::endgroup::"
  check "$scenario" "$work/requests.jsonl" "$work/blocked-hosts"
  ;;
check)
  [[ $# == 4 ]] || fail "usage: dependency-review-offline.sh check <scenario-file> <request-record> <blocked-hosts-file>"
  check "$2" "$3" "$4"
  ;;
*)
  echo "usage: dependency-review-offline.sh <start|verify|check> ..." >&2
  exit 2
  ;;
esac
