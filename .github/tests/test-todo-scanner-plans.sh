#!/usr/bin/env bash
# Failure plans preserve each observed read and any subsequent operations.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'fixture diff\n' >"$work/diff"
jq '.[2]' "$root/.github/tests/todo-scanner/cases.json" >"$work/healthy.json"
compile() {
  jq --rawfile diff "$work/diff" -f "$root/.github/tests/todo-scanner/plan.jq" "$1" >"$work/plan.json"
}
compile "$work/healthy.json"
jq -e '.Exchanges|length == 5 and .[4].Response == "fixture diff\n"' "$work/plan.json" >/dev/null
jq '. + {ForbiddenOutput:["Issue created:"],InitialReads:[
  {Method:"GET",Path:"/repos/offline/fixture/issues?per_page=100&page=1&state=open",Status:422,Response:"{\"message\":\"Offline issue read failure\"}"},
  {Method:"GET",Path:"/repos/offline/fixture/milestones?per_page=100&page=1&state=open",Status:200,Response:"[]"}]}' \
  "$work/healthy.json" >"$work/issues.json"
compile "$work/issues.json"
jq -e '.WantFailure == false and .ForbiddenOutput == ["Issue created:"] and
  (.Exchanges|length == 5 and .[2].Status == 422 and .[2].Response == "{\"message\":\"Offline issue read failure\"}" and .[3].Status == 200)' "$work/plan.json" >/dev/null
jq '.InitialReads[1].Status=422 | .InitialReads[1].Response="{\"message\":\"Offline milestone read failure\"}" |
  .InitialReads[0].Status=200 | .InitialReads[0].Response="[{\"number\":11,\"title\":\"Tracked\"}]"' \
  "$work/issues.json" >"$work/milestones.json"
compile "$work/milestones.json"
jq -e '.Exchanges|length == 5 and .[2].Status == 200 and
  .[2].Response == "[{\"number\":11,\"title\":\"Tracked\"}]" and .[3].Status == 422 and
  .[3].Path == "/repos/offline/fixture/milestones?per_page=100&page=1&state=open"' "$work/plan.json" >/dev/null
jq '. + {DiffError:true}' "$work/healthy.json" >"$work/diff-error.json"
compile "$work/diff-error.json"
jq -e '.Exchanges|length == 6 and .[4].Status == 503 and .[5].Status == 503' "$work/plan.json" >/dev/null
echo 'PASS: healthy, rejected-read, partial-read and diff-failure replay plans'
