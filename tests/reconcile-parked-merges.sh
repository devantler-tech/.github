#!/usr/bin/env bash
# Prove the parked-merge reconciler revokes only what a fresh read still shows as
# parked, and that an incomplete census changes nothing and is never reported clean.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/reconcile-parked-merges.sh"
workflow="$root/.github/workflows/reconcile-parked-merges.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
[[ -f "$script" ]] || fail 'reconciler is missing'
mkdir "$work/bin"
# Fixtures: $FIX/control, $FIX/page-<cursor or first>, $FIX/read-<number> before a
# revocation and $FIX/after-<number> once one has been recorded in $CALLS.
cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'pr merge' ]]; then
  printf 'disable %s %s\n' "$3" "$6" >>"$CALLS"
  [[ ! -e "$FIX/refuse-$3" ]] || exit 1
  exit 0
fi
[[ "$1 $2" == 'api graphql' ]] || exit 99
query="" q="" after="" number="" id="" jq_expression=""
shift 2
while (($#)); do
  case "$1" in
    -f | -F)
      case "$2" in
        query=*) query="${2#query=}" ;;
        q=*) q="${2#q=}" ;;
        after=*) after="${2#after=}" ;;
        number=*) number="${2#number=}" ;;
        id=*) id="${2#id=}" ;;
      esac
      shift 2
      ;;
    --jq)
      jq_expression="$2"
      shift 2
      ;;
    *) exit 98 ;;
  esac
done
case "$query" in
  *dequeuePullRequest*)
    printf 'dequeue %s\n' "$id" >>"$CALLS"
    printf '{"data":{}}\n'
    ;;
  *search*)
    if [[ "$q" != *label:blocked* ]]; then
      cat "$FIX/control"
    else
      [[ "$q" == *'is:open archived:false'* ]] || exit 97
      file="$FIX/page-${after:-first}"
      [[ -e "$file" ]] || exit 1
      cat "$file"
    fi
    ;;
  *labels*)
    if grep -q "^disable $number \|^dequeue PR_$number\$" "$CALLS" && [[ -e "$FIX/after-$number" ]]; then
      cat "$FIX/after-$number"
    else
      [[ -e "$FIX/read-$number" ]] || exit 1
      cat "$FIX/read-$number"
    fi
    ;;
  *)
    # The real disarm helper's own state read.
    armed=null
    [[ ! -e "$FIX/armed-$number" ]] || armed='{"enabledAt":"2026-11-02T00:00:00Z"}'
    queue=false
    [[ ! -e "$FIX/queued-$number" ]] || queue=true
    jq -cr "$jq_expression" <<<"{\"data\":{\"repository\":{\"pullRequest\":{\"id\":\"PR_$number\",\"isInMergeQueue\":$queue,\"autoMergeRequest\":$armed,\"mergeQueueEntry\":null}}}}"
    ;;
esac
SH
chmod +x "$work/bin/gh"

node() { # number armed queued
  local auto=null
  [[ "$2" == false ]] || auto='{"enabledAt":"2026-11-02T00:00:00Z"}'
  printf '{"number":%s,"isInMergeQueue":%s,"autoMergeRequest":%s,"repository":{"nameWithOwner":"devantler-tech/platform"}}' \
    "$1" "$3" "$auto"
}
page() { # total next cursor nodes...
  local total="$1" next="$2" cursor="$3" nodes
  shift 3
  nodes="$(IFS=,; printf '%s' "$*")"
  printf '{"data":{"search":{"issueCount":%s,"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":[%s]}}}\n' \
    "$total" "$next" "$cursor" "$nodes"
}
state() { # state armed queued labels
  local auto=null labels
  [[ "$2" == false ]] || auto='{"enabledAt":"2026-11-02T00:00:00Z"}'
  labels="$(jq -cn --arg labels "$4" '$labels | split(",") | map({name:.})')"
  printf '{"data":{"repository":{"pullRequest":{"state":"%s","isInMergeQueue":%s,"autoMergeRequest":%s,"labels":{"pageInfo":{"hasNextPage":%s},"nodes":%s}}}}}\n' \
    "$1" "$3" "$auto" "${5:-false}" "$labels"
}
fresh() {
  export FIX="$work/fix" CALLS="$work/calls"
  rm -rf "$FIX"
  mkdir "$FIX"
  : >"$CALLS"
  page 40 false null >"$FIX/control"
}
# Assert one run's exit status, its mutations and a line of its output.
expect() {
  local name="$1" want="$2" calls="$3" marker="$4" status=0
  env -i PATH="$work/bin:$PATH" FIX="$FIX" CALLS="$CALLS" bash "$script" >"$work/log" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || fail "$name returned $status, expected $want: $(cat "$work/log")"
  [[ "$(cat "$CALLS")" == "$calls" ]] || fail "$name mutated [$(cat "$CALLS")], expected [$calls]"
  grep -Fq "$marker" "$work/log" || fail "$name lost [$marker]: $(cat "$work/log")"
  if [[ "$want" == 2 ]]; then
    ! grep -q 'parked=' "$work/log" || fail "$name printed a census from an incomplete read"
  fi
  echo "PASS: $name"
}

fresh
page 1 false null "$(node 7 true false)" >"$FIX/page-first"
state OPEN true false blocked,talos >"$FIX/read-7"
state OPEN false false blocked >"$FIX/after-7"
touch "$FIX/armed-7"
expect 'armed-then-labelled is disarmed' 0 'disable 7 devantler-tech/platform' 'parked=1 revoked=1 failed=0'

fresh
page 1 false null "$(node 8 false true)" >"$FIX/page-first"
state OPEN false true blocked >"$FIX/read-8"
state OPEN false false blocked >"$FIX/after-8"
touch "$FIX/queued-8"
expect 'a queued parked pull request is dequeued' 0 'dequeue PR_8' 'parked=1 revoked=1 failed=0'

fresh
page 1 false null "$(node 9 false false)" >"$FIX/page-first"
expect 'a parked pull request with nothing pending is left alone' 0 '' 'parked=1 revoked=0 failed=0'

fresh
page 0 false null >"$FIX/page-first"
expect 'no parked pull requests is clean once the control saw some' 0 '' 'parked=0 revoked=0 failed=0'

fresh
page 2 true '"next"' "$(node 9 false false)" >"$FIX/page-first"
page 2 false null "$(node 7 true false)" >"$FIX/page-next"
state OPEN true false blocked >"$FIX/read-7"
state OPEN false false blocked >"$FIX/after-7"
touch "$FIX/armed-7"
expect 'a later page is reconciled too' 0 'disable 7 devantler-tech/platform' 'parked=2 revoked=1 failed=0'

fresh
page 1 false null "$(node 7 true false)" >"$FIX/page-first"
state OPEN true false talos >"$FIX/read-7"
expect 'a removed label keeps its legitimate arming' 0 '' 'parked=1 revoked=0 failed=0'

fresh
page 1 false null "$(node 7 true false)" >"$FIX/page-first"
state CLOSED true false blocked >"$FIX/read-7"
expect 'a closed pull request is left alone' 0 '' 'parked=1 revoked=0 failed=0'

fresh
page 1 false null "$(node 7 true false)" >"$FIX/page-first"
state OPEN true false blocked true >"$FIX/read-7"
expect 'truncated labels are a failure, not a decision' 1 '' 'could not re-read'

fresh
page 2 false null "$(node 7 true false)" "$(node 8 true false)" >"$FIX/page-first"
state OPEN true false blocked >"$FIX/read-7"
state OPEN true false blocked >"$FIX/after-7"
state OPEN true false blocked >"$FIX/read-8"
state OPEN false false blocked >"$FIX/after-8"
touch "$FIX/armed-7" "$FIX/armed-8"
expect 'a revocation that does not stick fails and the rest still run' 1 \
  $'disable 7 devantler-tech/platform\ndisable 8 devantler-tech/platform' 'still present'

fresh
page 2 false null "$(node 7 true false)" "$(node 8 true false)" >"$FIX/page-first"
state OPEN true false blocked >"$FIX/read-7"
state OPEN true false blocked >"$FIX/read-8"
state OPEN false false blocked >"$FIX/after-8"
touch "$FIX/armed-7" "$FIX/armed-8" "$FIX/refuse-7"
expect 'a refused revocation fails and the rest still run' 1 \
  $'disable 7 devantler-tech/platform\ndisable 8 devantler-tech/platform' 'could not revoke'

fresh
page 0 false null >"$FIX/control"
page 0 false null >"$FIX/page-first"
expect 'a token that sees no pull request is UNKNOWN' 2 '' 'unfiltered control saw no'

fresh
printf '{"errors":[{"message":"nope"}],"data":{"search":{"issueCount":40}}}\n' >"$FIX/control"
page 1 false null "$(node 7 true false)" >"$FIX/page-first"
expect 'a control with errors is UNKNOWN' 2 '' 'unfiltered control saw no'

fresh
expect 'a failed search is UNKNOWN' 2 '' 'parked search failed'

fresh
page 2 false null "$(node 7 true false)" >"$FIX/page-first"
expect 'a short search changes nothing and is UNKNOWN' 2 '' 'returned 1 of 2'

fresh
printf '{"errors":[{"message":"partial"}],"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false},"nodes":[]}}}\n' \
  >"$FIX/page-first"
expect 'a page with errors is UNKNOWN' 2 '' 'incomplete page'

fresh
page 1 true null "$(node 7 true false)" >"$FIX/page-first"
expect 'more results without a cursor is UNKNOWN' 2 '' 'no cursor'

# The workflow stays a schedule-only main job on its reviewed source, since a
# dispatch could choose a ref, and the token is the only authority it gets. Each mutation proves the check can refuse.
verify_workflow() {
  jq -e '
    (.on | keys == ["schedule"]) and
    .permissions == {} and
    (.jobs | keys == ["reconcile"]) and
    (.jobs.reconcile.if | gsub("\\s+";" ") | sub(" $";"")) ==
      "github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && github.event_name == '\''schedule'\''" and
    .jobs.reconcile.permissions == {contents:"read"} and
    .jobs.reconcile.steps[1].with == {ref:"${{ github.workflow_sha }}","persist-credentials":false} and
    .jobs.reconcile.steps[2].with == {
      "client-id":"${{ vars.APP_CLIENT_ID }}","private-key":"${{ secrets.APP_PRIVATE_KEY }}",
      owner:"devantler-tech","permission-metadata":"read",
      "permission-contents":"write","permission-pull-requests":"write"} and
    .jobs.reconcile.steps[3].env == {GH_TOKEN:"${{ steps.app-token.outputs.token }}"} and
    .jobs.reconcile.steps[3].run == "bash scripts/reconcile-parked-merges.sh" and
    .jobs.reconcile["continue-on-error"] == null and
    all(.jobs.reconcile.steps[]; .if == null and .["continue-on-error"] == null) and
    (.jobs.reconcile.steps | length == 4)
  ' "$1" >/dev/null
}
yq -o=json '.' "$workflow" >"$work/workflow.json"
verify_workflow "$work/workflow.json" || fail 'workflow boundary changed'
echo 'PASS: workflow boundary'
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$work/workflow.json" >"$work/mutated.json"
  if verify_workflow "$work/mutated.json"; then
    fail "workflow boundary accepted $name"
  fi
  echo "PASS: workflow boundary refuses $name"
done <<'MUTATIONS'
a pull request trigger	.on.pull_request={}
a manual trigger	.on.workflow_dispatch={}
a branch checkout	.jobs.reconcile.steps[1].with.ref="${{ github.head_ref }}"
persisted credentials	.jobs.reconcile.steps[1].with["persist-credentials"]=true
wider token scope	.jobs.reconcile.steps[2].with["permission-workflows"]="write"
job write authority	.jobs.reconcile.permissions.issues="write"
any branch	.jobs.reconcile.if="github.repository == 'devantler-tech/.github'"
a skipped reconciliation	.jobs.reconcile.steps[3].if="false"
an ignored step failure	.jobs.reconcile.steps[3]["continue-on-error"]=true
an ignored job failure	.jobs.reconcile["continue-on-error"]=true
MUTATIONS
