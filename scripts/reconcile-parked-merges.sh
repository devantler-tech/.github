#!/usr/bin/env bash
# Revoke any pending merge on a pull request labelled `blocked`. Required
# workflows never receive label events, so a label added after arming starts no
# evaluation; this scheduled read is what catches that order.
# Exit 0: every pending merge found on a parked PR is gone. Exit 1: a revocation
# failed or did not stick. Exit 2: the census could not be established.
set -euo pipefail
org=devantler-tech
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

unknown() {
  echo "parked-merges: UNKNOWN; $*" >&2
  exit 2
}

# shellcheck disable=SC2016 # GraphQL variables are literal query parameters.
search_query='query($q:String!,$after:String){search(query:$q,type:ISSUE,first:100,after:$after){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number isInMergeQueue autoMergeRequest{enabledAt} repository{nameWithOwner}}}}}'
# shellcheck disable=SC2016 # GraphQL variables are literal query parameters.
read_query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){state isInMergeQueue autoMergeRequest{enabledAt} labels(first:100){pageInfo{hasNextPage} nodes{name}}}}}'

# A token that reaches no repository returns an empty parked search, so an empty
# result only counts once the same token is shown to see pull requests at all.
control="$(gh api graphql -f query="$search_query" -f q="org:$org is:pr")" ||
  unknown 'the unfiltered control query failed'
jq -e '(has("errors") | not) and (.data.search.issueCount | type == "number" and . > 0)' \
  <<<"$control" >/dev/null || unknown 'the unfiltered control saw no pull requests'

: >"$work/parked"
after=""
while :; do
  args=(-f query="$search_query" -f q="org:$org is:pr is:open archived:false label:blocked")
  [[ -z "$after" ]] || args+=(-f after="$after")
  page="$(gh api graphql "${args[@]}")" || unknown 'the parked search failed'
  jq -e '
    (has("errors") | not) and
    (.data.search.issueCount | type == "number") and
    (.data.search.pageInfo.hasNextPage | type == "boolean") and
    (.data.search.nodes | type == "array") and
    all(.data.search.nodes[];
      (.number | type == "number") and
      (.isInMergeQueue | type == "boolean") and
      (.repository.nameWithOwner | type == "string"))
  ' <<<"$page" >/dev/null || unknown 'the parked search returned an incomplete page'
  total="$(jq -r '.data.search.issueCount' <<<"$page")"
  jq -r '.data.search.nodes[] |
    [.repository.nameWithOwner, .number, (.autoMergeRequest != null or .isInMergeQueue)] | @tsv' \
    <<<"$page" >>"$work/parked"
  [[ "$(jq -r '.data.search.pageInfo.hasNextPage' <<<"$page")" == true ]] || break
  after="$(jq -r '.data.search.pageInfo.endCursor // ""' <<<"$page")"
  [[ -n "$after" ]] || unknown 'the parked search has more results and no cursor'
done
seen="$(wc -l <"$work/parked" | tr -d ' ')"
[[ "$seen" == "$total" ]] || unknown "the parked search returned $seen of $total pull requests"

# Print the current state of one pull request: parked|clear, then pending true|false.
read_state() {
  local repository="$1" number="$2" snapshot
  snapshot="$(gh api graphql -f query="$read_query" -f owner="${repository%%/*}" \
    -f name="${repository#*/}" -F number="$number")" || return 1
  jq -er '
    select(has("errors") | not) | .data.repository.pullRequest |
    select((.state | type == "string") and (.isInMergeQueue | type == "boolean") and
      .labels.pageInfo.hasNextPage == false and (.labels.nodes | type == "array")) |
    [(if .state == "OPEN" and any(.labels.nodes[]; .name == "blocked") then "parked" else "clear" end),
      (.autoMergeRequest != null or .isInMergeQueue)] | @tsv
  ' <<<"$snapshot"
}

revoked=0 failed=0
while IFS=$'\t' read -r repository number pending; do
  [[ "$pending" == true ]] || continue
  # Search results lag: act only on a fresh read that still shows the park.
  if ! state="$(read_state "$repository" "$number")"; then
    echo "::error::$repository#$number: could not re-read the parked pull request."
    failed=$((failed + 1))
    continue
  fi
  [[ "$state" == $'parked\ttrue' ]] || continue
  if ! bash "$root/.scripts/disarm-auto-merge.sh" "$repository" "$number"; then
    echo "::error::$repository#$number: could not revoke its pending merge."
    failed=$((failed + 1))
    continue
  fi
  if ! state="$(read_state "$repository" "$number")" || [[ "$state" == *$'\ttrue' ]]; then
    echo "::error::$repository#$number: its pending merge is still present after revocation."
    failed=$((failed + 1))
    continue
  fi
  echo "revoked $repository#$number"
  revoked=$((revoked + 1))
done <"$work/parked"

echo "parked-merges: parked=$seen revoked=$revoked failed=$failed"
[[ "$failed" == 0 ]] || exit 1
