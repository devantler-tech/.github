#!/usr/bin/env bash
# Execute the workflow's real Bash decisions. The only GitHub interface is an
# offline recorder; unknown commands fail instead of falling through to gh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/enable-auto-merge.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/.devantler-tech-actions"
cp -R "$root/.scripts" "$work/.devantler-tech-actions/.scripts"
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
  .APPROVE_OUTCOME == "${{ steps.approve.outcome }}"
' >/dev/null || {
  echo 'FAIL: production workflow output bindings changed' >&2
  exit 1
}
fixture="$root/.github/tests/merge-gate-fixtures/green-cr-at-head-premerge-compact"
cp "$fixture/comments.json" "$work/comments-fixture.json"
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
    if [[ "$*" == *'autoMergeRequest{enabledAt}'* ]]; then
      expected_query='query=query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){id isInMergeQueue autoMergeRequest{enabledAt} mergeQueueEntry{enqueuedAt}}}}'
      expected_filter='.data.repository.pullRequest | "\(.id) \(.autoMergeRequest != null) \(.isInMergeQueue) \(.autoMergeRequest.enabledAt // "null") \(.mergeQueueEntry.enqueuedAt // "null")"'
      [[ "$#" == 12 && "$3" == -f && "$4" == "$expected_query" &&
        "$5" == -f && "$6" == owner=fixture && "$7" == -f && "$8" == name=repo &&
        "$9" == -F && "${10}" == number=42 && "${11}" == --jq && "${12}" == "$expected_filter" ]] || {
        echo "unexpected offline GitHub command: $*" >&2; exit 1;
      }
      [[ "$FIXTURE_FAILURE" != lookup ]] || exit 1
      printf 'PR_fixture false false null null\n'
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
cd "$work"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
run_step() {
  local script="$1"
  shift
  if ! env "$@" bash "$script.sh" >"$work/$script.log" 2>&1; then
    cat "$work/$script.log" >&2
    return 1
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
[[ "$(wc -l <"$FIXTURE_LOG" | tr -d ' ')" == 3 ]] || fail 'positive fixture did not approve and arm exactly once'
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
[[ "$(wc -l <"$FIXTURE_LOG" | tr -d ' ')" == 3 ]] || fail 'enforced cleanup or approval was bypassed'
if grep -q '^pr merge' "$FIXTURE_LOG"; then fail 'enforced mode armed auto-merge'; fi
grep -qx "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" "$FIXTURE_LOG" || fail 'enforced approval lost head'
[[ "$(sed -n '1p;3p' "$FIXTURE_LOG" | grep -c '^api graphql ')" == 2 &&
"$(sed -n '2p' "$FIXTURE_LOG")" == "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" ]] || fail 'cleanup and approval order changed'
export FIXTURE_FAILURE=lookup
: >"$FIXTURE_LOG"
if ENFORCED=true bash approve.sh >"$work/cleanup-error" 2>&1; then fail 'failed cleanup allowed approval'; fi
if grep -q 'event=APPROVE' "$FIXTURE_LOG"; then fail 'cleanup failure reached approval'; fi
if ENFORCED=true APPROVE_OUTCOME=success bash arm.sh >"$work/cleanup-error" 2>&1; then fail 'failed cleanup accepted enforced handoff'; fi
echo 'PASS: workflow approval and arming decisions executed offline with exact head bindings'
