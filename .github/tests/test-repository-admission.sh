#!/usr/bin/env bash
# Exercise the actual admission resolver with a closed, offline GitHub API.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
resolver="$root/.github/scripts/resolve-repository-admission.sh"
scratch=$(mktemp -d)
finished=0
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
# Remove disposable fixtures and turn an incomplete test run into a failure.
cleanup() {
  local rc=$?
  rm -rf "$scratch"
  [[ "$finished" == 1 || "$rc" != 0 ]] || rc=1
  exit "$rc"
}
trap cleanup EXIT
# End a failed control with an explicit nonzero result.
fail() {
  echo "repository admission test: $*" >&2
  exit 1
}
[[ -f "$resolver" ]] || fail 'resolver is missing'
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && "$1" == api && "$2" == "repos/$EXPECTED_REPOSITORY/contents/.github/pr-admission.json?ref=$EXPECTED_BASE" ]] || exit 91
printf '%s\n' "$2" >>"$TRACE"
[[ "${READ_FAILURE:-0}" == 0 ]] || exit 75
printf '%s\n' "$API_RESPONSE"
GH
chmod +x "$scratch/bin/gh"
source_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
base_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
candidate_sha=cccccccccccccccccccccccccccccccccccccccc
canonical='devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/main'
count=0
# Encode one synthetic contract in the real contents-API response shape.
response() {
  jq -cn --arg text "$1" '{type:"file",encoding:"base64",content:($text|@base64)}'
}
valid_response=$(response '{"version":1,"timeout-minutes":10}')

# Run one complete resolver process; a refusal must publish no partial success.
run_case() {
  local label="$1" expected="$2" result=0
  shift 2
  : >"$scratch/output"
  : >"$scratch/trace"
  env PATH="$scratch/bin:$PATH" GH_TOKEN=synthetic-read-only-token \
    GITHUB_OUTPUT="$scratch/output" TRACE="$scratch/trace" \
    TARGET_REPOSITORY=devantler-tech/monorepo EVENT_NAME=pull_request \
    WORKFLOW_REF="$canonical" WORKFLOW_SHA="$source_sha" CANDIDATE_SHA="$candidate_sha" \
    PULL_REQUEST_BASE_SHA="$base_sha" MERGE_GROUP_BASE_SHA=dddddddddddddddddddddddddddddddddddddddd \
    DEFAULT_BRANCH=main PULL_REQUEST_BASE_REF=main MERGE_GROUP_BASE_REF=refs/heads/main \
    EXPECTED_REPOSITORY=devantler-tech/monorepo EXPECTED_BASE="$base_sha" \
    API_RESPONSE="$valid_response" READ_FAILURE=0 "$@" \
    bash "$resolver" >"$scratch/log" 2>&1 || result=$?
  if [[ "$expected" == reject ]]; then
    [[ "$result" != 0 && ! -s "$scratch/output" ]] || fail "$label admitted an invalid context or partial result"
  else
    [[ "$result" == 0 ]] || {
      cat "$scratch/log" >&2
      fail "$label refused a valid context"
    }
    [[ "$(cat "$scratch/output")" == "$expected" ]] || fail "$label returned the wrong immutable binding or budget"
  fi
  count=$((count + 1))
}
expected=$(printf 'run=true\ntrusted-sha=%s\ntimeout-minutes=10' "$base_sha")
run_case 'pull request base' "$expected"
[[ "$(wc -l <"$scratch/trace" | tr -d ' ')" == 1 ]] || fail 'expected exactly one bounded contract read'
run_case 'merge group base' "$expected" EVENT_NAME=merge_group MERGE_GROUP_BASE_SHA="$base_sha" PULL_REQUEST_BASE_SHA=invalid
run_case 'source repository required invocation' "$expected" TARGET_REPOSITORY=devantler-tech/.github EXPECTED_REPOSITORY=devantler-tech/.github
run_case 'product default branch need not be main' "$expected" DEFAULT_BRANCH=develop PULL_REQUEST_BASE_REF=develop
run_case 'minimum budget' "$(printf 'run=true\ntrusted-sha=%s\ntimeout-minutes=1' "$base_sha")" \
  API_RESPONSE="$(response '{"version":1,"timeout-minutes":1}')"
run_case 'existing long-suite budget' "$(printf 'run=true\ntrusted-sha=%s\ntimeout-minutes=90' "$base_sha")" \
  API_RESPONSE="$(response '{"version":1,"timeout-minutes":90}')"

source_only=$(printf 'run=false\ntrusted-sha=%s\ntimeout-minutes=10' "$source_sha")
run_case 'ordinary source pull request' "$source_only" TARGET_REPOSITORY=devantler-tech/.github \
  WORKFLOW_REF='devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/pull/42/merge' READ_FAILURE=1
[[ ! -s "$scratch/trace" ]] || fail 'ordinary source events must not read candidate-controlled contracts'
run_case 'ordinary source merge group' "$source_only" TARGET_REPOSITORY=devantler-tech/.github EVENT_NAME=merge_group \
  WORKFLOW_REF='devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/gh-readonly-queue/main/pr-42-native' READ_FAILURE=1
[[ ! -s "$scratch/trace" ]] || fail 'ordinary source merge groups must not read candidate-controlled contracts'

run_case 'unknown workflow origin' reject WORKFLOW_REF='devantler-tech/monorepo/.github/workflows/repository-pr-admission.yaml@refs/heads/main'
run_case 'candidate origin in consumer' reject WORKFLOW_REF='devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/pull/42/merge'
run_case 'unrecognized source ref' reject TARGET_REPOSITORY=devantler-tech/.github WORKFLOW_REF='devantler-tech/.github/.github/workflows/repository-pr-admission.yaml@refs/heads/unreviewed'
run_case 'unsupported event' reject EVENT_NAME=push
run_case 'invalid repository' reject TARGET_REPOSITORY='devantler-tech/monorepo?other=1'
run_case 'missing workflow source' reject WORKFLOW_SHA=''
run_case 'mutable candidate' reject CANDIDATE_SHA=main
run_case 'missing PR base' reject PULL_REQUEST_BASE_SHA=''
run_case 'missing merge-group base' reject EVENT_NAME=merge_group MERGE_GROUP_BASE_SHA=''
run_case 'missing product default branch' reject DEFAULT_BRANCH=''
run_case 'nondefault PR base' reject PULL_REQUEST_BASE_REF=unreviewed
run_case 'missing PR base ref' reject PULL_REQUEST_BASE_REF=''
run_case 'nondefault merge-group base' reject EVENT_NAME=merge_group MERGE_GROUP_BASE_REF=refs/heads/unreviewed
run_case 'missing merge-group base ref' reject EVENT_NAME=merge_group MERGE_GROUP_BASE_REF=''
run_case 'failed contract read' reject READ_FAILURE=1
run_case 'linked contract' reject API_RESPONSE='{"type":"symlink","encoding":"base64","content":"e30="}'
run_case 'unknown encoding' reject API_RESPONSE='{"type":"file","encoding":"none","content":"e30="}'
run_case 'missing content' reject API_RESPONSE='{"type":"file","encoding":"base64"}'
run_case 'invalid encoded content' reject API_RESPONSE='{"type":"file","encoding":"base64","content":"?"}'
for invalid in \
  '' '{' '{} {}' '{"version":1}' \
  '{"version":2,"timeout-minutes":10}' \
  '{"version":1,"timeout-minutes":10,"extra":true}' \
  '{"version":1,"timeout-minutes":0}' \
  '{"version":1,"timeout-minutes":91}' \
  '{"version":1,"timeout-minutes":1.5}' \
  '{"version":1,"timeout-minutes":"10"}' \
  '{"version":1,"timeout-minutes":null}' \
  '{"version":1,"version":2,"timeout-minutes":10}' \
  '{"version":1,"timeout-minutes":90,"timeout-minutes":10}'; do
  run_case "invalid contract $invalid" reject API_RESPONSE="$(response "$invalid")"
done
workflow="$root/.github/workflows/repository-pr-admission.yaml"
[[ -f "$workflow" ]] || fail 'shared workflow source is missing'
# Inspect the actual workflow payload, not a second implementation of its runner.
check_workflow() {
  yq -o=json '.' "$1" | jq -e '
    .permissions == {} and
    .on.pull_request.types == ["opened","synchronize","reopened"] and
    (.on | has("merge_group") and (has("workflow_call") | not)) and
    (.jobs | keys | sort) == ["admission","resolve"] and
    .jobs.resolve.permissions == {contents:"read"} and
    .jobs.resolve["timeout-minutes"] == 5 and
    (.jobs.resolve.steps | length) == 3 and
    (.jobs.resolve.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$")) and
    .jobs.resolve.steps[0].with["egress-policy"] == "audit" and
    (.jobs.resolve.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
    .jobs.resolve.steps[1].with == {
      repository:"devantler-tech/.github",ref:"${{ github.workflow_sha }}",
      path:".admission-runner","persist-credentials":false
    } and
    .jobs.resolve.steps[2].id == "resolve" and
    .jobs.resolve.steps[2].run == "bash .admission-runner/.github/scripts/resolve-repository-admission.sh" and
    .jobs.resolve.steps[2].env == {
      GH_TOKEN:"${{ github.token }}",TARGET_REPOSITORY:"${{ github.repository }}",
      EVENT_NAME:"${{ github.event_name }}",WORKFLOW_REF:"${{ github.workflow_ref }}",
      WORKFLOW_SHA:"${{ github.workflow_sha }}",CANDIDATE_SHA:"${{ github.sha }}",
      PULL_REQUEST_BASE_SHA:"${{ github.event.pull_request.base.sha }}",
      MERGE_GROUP_BASE_SHA:"${{ github.event.merge_group.base_sha }}",
      DEFAULT_BRANCH:"${{ github.event.repository.default_branch }}",
      PULL_REQUEST_BASE_REF:"${{ github.event.pull_request.base.ref }}",
      MERGE_GROUP_BASE_REF:"${{ github.event.merge_group.base_ref }}"
    } and
    .jobs.resolve.outputs == {
      run:"${{ steps.resolve.outputs.run }}",
      "trusted-sha":"${{ steps.resolve.outputs.trusted-sha }}",
      "timeout-minutes":"${{ steps.resolve.outputs.timeout-minutes }}"
    } and
    .jobs.admission.needs == "resolve" and
    .jobs.admission.name == "${{ needs.resolve.outputs.run == \u0027true\u0027 && \u0027Run reviewed product admission\u0027 || \u0027Admission not selected\u0027 }}" and
    .jobs.admission.if == "needs.resolve.outputs.run == \u0027true\u0027" and
    .jobs.admission.permissions == {contents:"read"} and
    .jobs.admission["timeout-minutes"] == "${{ fromJSON(needs.resolve.outputs.timeout-minutes) }}" and
    (.jobs.admission.steps | length) == 3 and
    (.jobs.admission.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$")) and
    .jobs.admission.steps[0].with["egress-policy"] == "audit" and
    (.jobs.admission.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
    .jobs.admission.steps[1].with == {
      repository:"${{ github.repository }}",ref:"${{ github.event_name == \u0027merge_group\u0027 && github.event.merge_group.base_sha || github.event.pull_request.base.sha }}",
      path:".repository-admission","persist-credentials":false
    } and
    .jobs.admission.steps[2].uses == "./.repository-admission/.github/actions/pr-admission" and
    .jobs.admission.steps[2].with == {"candidate-sha":"${{ github.sha }}"} and
    all(.jobs[].steps[]; .if == null and (.["continue-on-error"] // false) == false)
  ' >/dev/null
}
check_workflow "$workflow" || fail 'shared workflow loses the immutable read-only admission boundary'
# shellcheck disable=SC2016 # GitHub expressions remain literal mutation data.
for mutation in \
  '.jobs.resolve.permissions.contents = "write"' \
  '.jobs.resolve.steps[1].with.ref = "${{ github.sha }}"' \
  '.jobs.resolve.steps[1].with["persist-credentials"] = true' \
  '.jobs.resolve.steps[2].env.PULL_REQUEST_BASE_SHA = "${{ github.sha }}"' \
  '.jobs.resolve.steps[2].env.MERGE_GROUP_BASE_SHA = "${{ github.sha }}"' \
  '.jobs.resolve.steps[2].env.DEFAULT_BRANCH = "main"' \
  '.jobs.resolve.steps[2].env.PULL_REQUEST_BASE_REF = "${{ github.head_ref }}"' \
  '.jobs.resolve.steps[2].env.MERGE_GROUP_BASE_REF = "refs/heads/unreviewed"' \
  'del(.jobs.resolve.outputs["trusted-sha"])' \
  '.jobs.admission.steps[1].with.ref = "${{ github.sha }}"' \
  '.jobs.admission.name = "Run reviewed product admission"' \
  '.jobs.admission.steps[2].uses = "./candidate/.github/actions/pr-admission"' \
  '.jobs.admission.steps[2].if = "false"' \
  '.jobs.admission.steps[2]["continue-on-error"] = true' \
  '.jobs.admission["timeout-minutes"] = 360' \
  '.jobs.admission.permissions.contents = "write"'; do
  yq "$mutation" "$workflow" >"$scratch/workflow.yaml"
  if check_workflow "$scratch/workflow.yaml"; then
    fail "unsafe workflow mutation was accepted: $mutation"
  fi
done
finished=1
echo "repository admission: $count real resolver contexts and contract controls passed"
