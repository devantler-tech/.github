#!/usr/bin/env bash
# Execute the workflow's real Bash decisions. The only GitHub interface is an
# offline recorder; unknown commands fail instead of falling through to gh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/enable-auto-merge.yaml}"
policy_script="${2:-$root/.scripts/auto-merge-policy.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/.devantler-tech-actions"
cp -R "$root/.scripts" "$work/.devantler-tech-actions/.scripts"
cp "$policy_script" "$work/.devantler-tech-actions/.scripts/auto-merge-policy.sh"
for id in gates approve; do
  [[ "$(ID="$id" yq -r '[.jobs."auto-merge".steps[] | select(.id == strenv(ID))] | length' "$workflow")" == 1 ]] || {
    echo "FAIL: expected exactly one $id body" >&2
    exit 1
  }
  ID="$id" yq -r '.jobs."auto-merge".steps[] | select(.id == strenv(ID)) | .run' "$workflow" >"$work/$id.sh"
  [[ -s "$work/$id.sh" ]] || {
    echo "FAIL: missing $id body" >&2
    exit 1
  }
done
[[ "$(yq -r '[.jobs."auto-merge".steps[] | select(.name == "🔀 Enable Auto-Merge")] | length' "$workflow")" == 1 ]] || {
  echo 'FAIL: expected exactly one arming body' >&2
  exit 1
}
yq -r '.jobs."auto-merge".steps[] | select(.name == "🔀 Enable Auto-Merge") | .run' "$workflow" >"$work/arm.sh"
yq -o=json '.jobs."auto-merge".steps' "$workflow" | jq -e '
  [.[] | select(.id == "approve" or .name == "🔀 Enable Auto-Merge") | .env] |
  length == 2 and all(.HEAD_SHA == "${{ steps.gates.outputs.head_sha }}" and
    .ENFORCED == "${{ steps.gates.outputs.enforced }}" and
    .PR_NUMBER == "${{ steps.pr.outputs.number }}" and .REPOSITORY == "${{ github.repository }}")
' >/dev/null || {
  echo 'FAIL: production workflow output bindings changed' >&2
  exit 1
}
expected_enforce="\${{ (inputs.enforce-review-gates || vars.ENFORCE_MERGE_GATES == 'true') && 'true' || 'false' }}"
yq -o=json '.jobs."auto-merge".steps[] | select(.id == "gates") | .env' "$workflow" | jq -e --arg enforcement "$expected_enforce" '
  .HEAD_SHA == "${{ steps.pr.outputs.head_sha }}" and .ENFORCE == $enforcement and
  .EVENT_NAME == "${{ github.event_name }}"
' >/dev/null || {
  echo 'FAIL: production workflow output bindings changed' >&2
  exit 1
}
yq -o=json '.jobs."auto-merge".steps[] | select(.name == "🔀 Enable Auto-Merge") | .env' "$workflow" | jq -e '
  .APPROVE_OUTCOME == "${{ steps.approve.outcome }}" and
  .POLICY_ALLOWED == "${{ steps.approve.outputs.policy_allowed }}"
' >/dev/null || {
  echo 'FAIL: production workflow output bindings changed' >&2
  exit 1
}
fixture="$root/.github/tests/merge-gate-fixtures/green-cr-at-head-premerge-compact"
cp "$fixture/comments.json" "$work/comments-fixture.json"
jq -n --arg head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{data:{repository:{pullRequest:{
  headRefOid:$head, state:"OPEN", isDraft:false,
  author:{login:"dependabot",__typename:"Bot"},
  labels:{totalCount:0,nodes:[],pageInfo:{hasNextPage:false}}
}}}}' >"$work/policy-fixture.json"
cp "$work/policy-fixture.json" "$work/policy-base.json"
printf '{"armed":false,"queued":false}\n' >"$work/merge-state.json"
jq '{data:{repository:{pullRequest:{reviews:{nodes:map({author:{login:.user.login,__typename:"Bot"},body:(.body // ""),state,commit:{oid:.commit_id},submittedAt:.submitted_at,lastEditedAt:null})}}}}}' "$fixture/reviews.json" >"$work/reviews-fixture.json"
cat >"$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FIXTURE_LOG"
case "$*" in
  "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD")
    [[ "$FIXTURE_FAILURE" != approval ]] || exit 1
    printf '{}\n'
    ;;
  "api repos/fixture/repo --jq .allow_auto_merge") printf 'true\n' ;;
  "pr merge 42 --auto --squash --repo fixture/repo --match-head-commit $FIXTURE_HEAD")
    [[ "$FIXTURE_FAILURE" != merge ]] || exit 1
    jq '.armed=true' "$FIXTURE_ROOT/merge-state.json" >"$FIXTURE_ROOT/merge-next.json"
    mv "$FIXTURE_ROOT/merge-next.json" "$FIXTURE_ROOT/merge-state.json"
    ;;
  "pr merge 42 --disable-auto --repo fixture/repo")
    [[ "$FIXTURE_FAILURE" != disable ]] || exit 1
    jq '.armed=false' "$FIXTURE_ROOT/merge-state.json" >"$FIXTURE_ROOT/merge-next.json"
    mv "$FIXTURE_ROOT/merge-next.json" "$FIXTURE_ROOT/merge-state.json"
    ;;
  'api graphql -f query=mutation($id:ID!){dequeuePullRequest(input:{id:$id}){clientMutationId}} -f id=PR_fixture')
    [[ "$FIXTURE_FAILURE" != dequeue ]] || exit 1
    jq '.queued=false' "$FIXTURE_ROOT/merge-state.json" >"$FIXTURE_ROOT/merge-next.json"
    mv "$FIXTURE_ROOT/merge-next.json" "$FIXTURE_ROOT/merge-state.json"
    ;;
  "api repos/fixture/repo/actions/runs/999 --jq .check_suite_id // empty") printf '7\n' ;;
  "api repos/fixture/repo/commits/$FIXTURE_HEAD/check-suites --paginate")
    printf '{"check_suites":[{"id":1,"created_at":"2026-07-11T09:00:00Z","pull_requests":[{"number":42}]}]}\n'
    ;;
  "api repos/fixture/repo/issues/42/timeline --paginate") printf '[]\n' ;;
  "api repos/fixture/repo/issues/42/comments --paginate") cat "$FIXTURE_ROOT/comments-fixture.json" ;;
  "api graphql "*)
    [[ "$*" == *' -f owner=fixture -f name=repo -F number=42'* && "$*" != *'mutation('* ]] || {
      echo "unexpected offline GitHub command: $*" >&2; exit 1;
    }
    if [[ "$*" == *'labels(first:100)'* ]]; then
      [[ "$FIXTURE_FAILURE" != policy ]] || exit 1
      cat "$FIXTURE_ROOT/policy-fixture.json"
    elif [[ "$*" == *'autoMergeRequest{enabledAt}'* ]]; then
      expected_query='query=query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id isInMergeQueue autoMergeRequest{enabledAt} mergeQueueEntry{enqueuedAt}}}}'
      expected_filter='.data.repository.pullRequest | "\(.id) \(.autoMergeRequest != null) \(.isInMergeQueue) \(.autoMergeRequest.enabledAt // "null") \(.mergeQueueEntry.enqueuedAt // "null")"'
      [[ "$#" == 12 && "$3" == -f && "$4" == "$expected_query" &&
        "$5" == -f && "$6" == owner=fixture && "$7" == -f && "$8" == name=repo &&
        "$9" == -F && "${10}" == number=42 && "${11}" == --jq && "${12}" == "$expected_filter" ]] || {
        echo "unexpected offline GitHub command: $*" >&2; exit 1;
      }
      [[ "$FIXTURE_FAILURE" != lookup ]] || exit 1
      jq -r '"PR_fixture \(.armed) \(.queued) null null"' "$FIXTURE_ROOT/merge-state.json"
    elif [[ "$*" == *'reviews(first:100,after:$endCursor)'* ]]; then
      cat "$FIXTURE_ROOT/reviews-fixture.json"
    else
      echo "unexpected offline GitHub command: $*" >&2; exit 1
    fi
    ;;
  *) echo "unexpected offline GitHub command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"
# Never let a real credential escape into the fixture processes.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
export GH_TOKEN=offline-fixture-not-a-credential
export FIXTURE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export HEAD_SHA="$FIXTURE_HEAD" PR_NUMBER=42 REPOSITORY=fixture/repo
export FIXTURE_LOG="$work/requests" GITHUB_OUTPUT="$work/outputs"
export FIXTURE_ROOT="$work" RUNNER_TEMP="$work" GITHUB_RUN_ID=999
export FIXTURE_FAILURE=none ENFORCE=false EVENT_NAME=pull_request
export TRUSTED_BOT_AUTHORS
TRUSTED_BOT_AUTHORS=$(yq -r '.env.TRUSTED_BOT_AUTHORS' "$workflow")
export POLICY_ALLOWED=true
cd "$work"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# Execute the named extracted workflow step with optional NAME=value overrides.
# On failure, print its captured log and return nonzero. A successful approval
# exports its policy output so the following arming step consumes the real
# decision rather than an independently invented permission to merge.
run_step() {
  local script="$1"
  shift
  if ! env "$@" bash "$script.sh" >"$work/$script.log" 2>&1; then
    cat "$work/$script.log" >&2
    return 1
  fi
  if [[ "$script" == approve ]]; then
    POLICY_ALLOWED=$(sed -n 's/^policy_allowed=//p' "$GITHUB_OUTPUT" | tail -n 1)
    export POLICY_ALLOWED
  fi
}

# A mutation-eligible, ready trusted-bot lifecycle is deliberately positive.
# Default-off production must approve AND arm, pinned to the proven head.
: >"$FIXTURE_LOG"
: >"$GITHUB_OUTPUT"
bash gates.sh >"$work/gates.log"
grep -qx 'armable=true' "$GITHUB_OUTPUT" || fail 'default-off lifecycle was not armable'
grep -qx "head_sha=$FIXTURE_HEAD" "$GITHUB_OUTPUT" || fail 'gate lost head binding'
HEAD_SHA="$(sed -n 's/^head_sha=//p' "$GITHUB_OUTPUT")"
ENFORCED="$(sed -n 's/^enforced=//p' "$GITHUB_OUTPUT")"
export HEAD_SHA ENFORCED
[[ "$ENFORCED" == false ]] || fail 'default-off gate lost enforcement output'
run_step approve
run_step arm APPROVE_OUTCOME=success
[[ "$(grep -cE 'event=APPROVE|^pr merge' "$FIXTURE_LOG")" == 2 ]] || fail 'positive fixture did not approve and arm exactly once'
grep -qx "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" "$FIXTURE_LOG" || fail 'approval lost reviewed head'
grep -qx "pr merge 42 --auto --squash --repo fixture/repo --match-head-commit $FIXTURE_HEAD" "$FIXTURE_LOG" || fail 'arming lost reviewed head'

# Review/comment events cannot arm while enforcement is off.
for EVENT_NAME in pull_request_review issue_comment; do
  export EVENT_NAME
  : >"$FIXTURE_LOG"
  : >"$GITHUB_OUTPUT"
  bash gates.sh >"$work/gates.log"
  grep -qx 'armable=false' "$GITHUB_OUTPUT" || fail 'default-off reviewer event became armable'
  [[ ! -s "$FIXTURE_LOG" ]] || fail 'default-off gate called GitHub'
done

# Unreadable approval is a hard stop, and failed approval must never arm.
export FIXTURE_FAILURE=approval
if ENFORCED=false bash approve.sh >"$work/approval-error" 2>&1; then fail 'approval API error accepted'; fi
grep -qF 'Failed to approve PR' "$work/approval-error" || fail 'wrong approval error'
: >"$FIXTURE_LOG"
if ENFORCED=false APPROVE_OUTCOME=failure bash arm.sh >"$work/arm-error" 2>&1; then fail 'failed approval armed'; fi
[[ ! -s "$FIXTURE_LOG" ]] || fail 'failed approval reached GitHub'
export FIXTURE_FAILURE=merge
if ENFORCED=false APPROVE_OUTCOME=success bash arm.sh >"$work/merge-error" 2>&1; then fail 'merge API error accepted'; fi
grep -qF 'Failed to enable auto-merge' "$work/merge-error" || fail 'wrong merge error'

# A label added after the first decision must prevent approval. The real
# approval step must read live policy; ignoring it leaks an actual mutation.
export FIXTURE_FAILURE=none
jq '.data.repository.pullRequest.labels = {totalCount:1,nodes:[{name:"blocked"}],pageInfo:{hasNextPage:false}}' \
  "$work/policy-fixture.json" >"$work/policy-next.json"
mv "$work/policy-next.json" "$work/policy-fixture.json"
printf '{"armed":true,"queued":true}\n' >"$work/merge-state.json"
: >"$FIXTURE_LOG"
run_step approve ENFORCED=false
if grep -q 'event=APPROVE' "$FIXTURE_LOG"; then fail 'blocked PR was approved'; fi
jq -e '.armed == false and .queued == false' "$work/merge-state.json" >/dev/null || fail 'blocked PR kept pending merge state'
jq '.data.repository.pullRequest.labels = {totalCount:0,nodes:[],pageInfo:{hasNextPage:false}}' \
  "$work/policy-fixture.json" >"$work/policy-next.json"
mv "$work/policy-next.json" "$work/policy-fixture.json"
: >"$FIXTURE_LOG"
run_step arm ENFORCED=false APPROVE_OUTCOME=success
if grep -q -- '--auto' "$FIXTURE_LOG"; then fail 'label removal armed without a new approval evaluation'; fi

# A new evaluation after unblock must still deliver ordinary bot automation.
: >"$FIXTURE_LOG"
run_step approve ENFORCED=false
run_step arm ENFORCED=false APPROVE_OUTCOME=success
grep -q -- '--auto' "$FIXTURE_LOG" || fail 'fresh unblocked evaluation did not arm'

# Recheck after approval too: a new block revokes classic and queue state.
jq '.data.repository.pullRequest.labels = {totalCount:1,nodes:[{name:"blocked"}],pageInfo:{hasNextPage:false}}' \
  "$work/policy-base.json" >"$work/policy-fixture.json"
printf '{"armed":true,"queued":true}\n' >"$work/merge-state.json"
: >"$FIXTURE_LOG"
run_step arm ENFORCED=false APPROVE_OUTCOME=success
if grep -q -- '--auto' "$FIXTURE_LOG"; then fail 'late blocked PR was armed'; fi
jq -e '.armed == false and .queued == false' "$work/merge-state.json" >/dev/null || fail 'late block kept pending merge state'

# Renovate owns resolved package-rule policy. Its valid native request is
# retained; a visibility label is not parking and cannot override ownership.
for login in renovate 'renovate[bot]'; do
  jq --arg login "$login" '.data.repository.pullRequest.author.login=$login |
    .data.repository.pullRequest.labels={totalCount:1,nodes:[{name:"security/review-required"}],pageInfo:{hasNextPage:false}}' \
    "$work/policy-base.json" >"$work/policy-fixture.json"
  for armed in true false; do
    jq -n --argjson armed "$armed" '{armed:$armed,queued:false}' >"$work/merge-state.json"
    : >"$FIXTURE_LOG"
    run_step approve ENFORCED=false
    run_step arm ENFORCED=false APPROVE_OUTCOME=success
    if grep -qE '^pr merge|dequeuePullRequest' "$FIXTURE_LOG"; then fail 'central workflow changed Renovate native arming'; fi
    jq -e --argjson armed "$armed" '.armed == $armed and .queued == false' "$work/merge-state.json" >/dev/null || fail 'Renovate native decision changed'
  done
done

# Both mutation boundaries consume complete current state. Error controls
# must fail rather than turn an unknown snapshot into permission to mutate.
while IFS=$'\t' read -r label mutation expected; do
  jq "$mutation" "$work/policy-base.json" >"$work/policy-fixture.json"
  for stage in approve arm; do
    export POLICY_ALLOWED=true
    : >"$FIXTURE_LOG"
    : >"$GITHUB_OUTPUT"
    if run_step "$stage" ENFORCED=false APPROVE_OUTCOME=success >"$work/negative.log" 2>&1; then
      [[ $expected == deny ]] || fail "$label did not fail closed at $stage"
    else
      [[ $expected == error ]] || {
        cat "$work/negative.log" >&2
        fail "$label errored instead of declining at $stage"
      }
    fi
    if grep -qE 'event=APPROVE|^pr merge|dequeuePullRequest' "$FIXTURE_LOG"; then fail "$label mutated at $stage"; fi
  done
done <<'POLICY_CASES'
untrusted author	.data.repository.pullRequest.author={login:"outside-contributor",__typename:"User"}	deny
bot name on user actor	.data.repository.pullRequest.author={login:"dependabot[bot]",__typename:"User"}	deny
changed head	.data.repository.pullRequest.headRefOid="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"	deny
draft	.data.repository.pullRequest.isDraft=true	deny
closed	.data.repository.pullRequest.state="CLOSED"	deny
merged	.data.repository.pullRequest.state="MERGED"	deny
query errors	.errors=[{message:"incomplete"}]	error
invalid error field	.errors=false	error
missing data	del(.data)	error
missing author	del(.data.repository.pullRequest.author)	error
missing draft	del(.data.repository.pullRequest.isDraft)	error
malformed head	.data.repository.pullRequest.headRefOid="not-a-head"	error
malformed labels	.data.repository.pullRequest.labels.nodes=null	error
missing label count	del(.data.repository.pullRequest.labels.totalCount)	error
fractional count	.data.repository.pullRequest.labels.totalCount=0.5	error
missing page proof	del(.data.repository.pullRequest.labels.pageInfo)	error
more labels	.data.repository.pullRequest.labels.pageInfo.hasNextPage=true	error
count mismatch	.data.repository.pullRequest.labels.totalCount=1	error
missing label name	.data.repository.pullRequest.labels={totalCount:1,nodes:[{}],pageInfo:{hasNextPage:false}}	error
duplicate labels	.data.repository.pullRequest.labels={totalCount:2,nodes:[{name:"other"},{name:"other"}],pageInfo:{hasNextPage:false}}	error
POLICY_CASES

# An unavailable policy read or either failed revocation cannot approve/arm.
for failure in policy lookup disable dequeue; do
  jq '.data.repository.pullRequest.labels={totalCount:1,nodes:[{name:"blocked"}],pageInfo:{hasNextPage:false}}' \
    "$work/policy-base.json" >"$work/policy-fixture.json"
  for stage in approve arm; do
    printf '{"armed":true,"queued":true}\n' >"$work/merge-state.json"
    : >"$FIXTURE_LOG"
    if run_step "$stage" FIXTURE_FAILURE="$failure" ENFORCED=false APPROVE_OUTCOME=success >"$work/refusal.log" 2>&1; then fail "$failure allowed $stage"; fi
    if grep -qE 'event=APPROVE|^pr merge 42 --auto ' "$FIXTURE_LOG"; then fail "$failure reached a privileged mutation"; fi
  done
done
cp "$work/policy-base.json" "$work/policy-fixture.json"
printf '{"armed":false,"queued":false}\n' >"$work/merge-state.json"

for authors in '[]' '{}' '["dependabot[bot]","dependabot[bot]"]' 'not-json'; do
  for stage in approve arm; do
    : >"$FIXTURE_LOG"
    if run_step "$stage" TRUSTED_BOT_AUTHORS="$authors" ENFORCED=false APPROVE_OUTCOME=success >"$work/authors-error" 2>&1; then fail 'invalid author policy accepted'; fi
    [[ ! -s "$FIXTURE_LOG" ]] || fail 'invalid author policy reached GitHub'
  done
done

# Enforced mode approves only the reviewed head and leaves arming to the
# engineer. It runs the actual shared disarm helper at both boundaries.
export FIXTURE_FAILURE=none
export ENFORCE=true EVENT_NAME=pull_request
: >"$GITHUB_OUTPUT"
run_step gates
grep -qx 'armable=true' "$GITHUB_OUTPUT" || fail 'current review did not clear enforced gates'
ENFORCED="$(sed -n 's/^enforced=//p' "$GITHUB_OUTPUT")"
HEAD_SHA="$(sed -n 's/^head_sha=//p' "$GITHUB_OUTPUT")"
[[ "$ENFORCED" == true && "$HEAD_SHA" == "$FIXTURE_HEAD" ]] || fail 'enforced gate outputs lost'
: >"$FIXTURE_LOG"
run_step approve
run_step arm APPROVE_OUTCOME=success
[[ "$(grep -c 'event=APPROVE' "$FIXTURE_LOG")" == 1 &&
"$(grep -cF "pullRequest(number:\$number){id isInMergeQueue" "$FIXTURE_LOG")" == 2 ]] || fail 'enforced cleanup or approval was bypassed'
if grep -q '^pr merge' "$FIXTURE_LOG"; then fail 'enforced mode armed auto-merge'; fi
grep -qx "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" "$FIXTURE_LOG" || fail 'enforced approval lost head'
policy_mutations=$(grep -E 'event=APPROVE|pullRequest\(number:[$]number\)\{id isInMergeQueue' "$FIXTURE_LOG")
[[ "$(sed -n '1p;3p' <<<"$policy_mutations" | grep -c '^api graphql ')" == 2 &&
"$(sed -n '2p' <<<"$policy_mutations")" == "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" ]] || fail 'cleanup and approval order changed'
export FIXTURE_FAILURE=lookup
: >"$FIXTURE_LOG"
if ENFORCED=true bash approve.sh >"$work/cleanup-error" 2>&1; then fail 'failed cleanup allowed approval'; fi
if grep -q 'event=APPROVE' "$FIXTURE_LOG"; then fail 'cleanup failure reached approval'; fi
if ENFORCED=true APPROVE_OUTCOME=success bash arm.sh >"$work/cleanup-error" 2>&1; then fail 'failed cleanup accepted enforced handoff'; fi
echo 'PASS: workflow approval and arming decisions executed offline with exact head bindings'
