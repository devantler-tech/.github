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
  "api graphql "*)
    [[ "$*" == *'autoMergeRequest{enabledAt}'* ]] || { echo 'unexpected GraphQL call' >&2; exit 1; }
    printf 'PR_fixture false false null null\n'
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
run_step approve ENFORCED=false
run_step arm ENFORCED=false APPROVE_OUTCOME=success
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
: >"$FIXTURE_LOG"
run_step approve ENFORCED=true
run_step arm ENFORCED=true APPROVE_OUTCOME=success
[[ "$(wc -l <"$FIXTURE_LOG" | tr -d ' ')" == 3 ]] || fail 'enforced cleanup or approval was bypassed'
if grep -q '^pr merge' "$FIXTURE_LOG"; then fail 'enforced mode armed auto-merge'; fi
grep -qx "api repos/fixture/repo/pulls/42/reviews -f event=APPROVE -f commit_id=$FIXTURE_HEAD" "$FIXTURE_LOG" || fail 'enforced approval lost head'
echo 'PASS: workflow approval and arming decisions executed offline with exact head bindings'
