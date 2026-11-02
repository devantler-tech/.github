#!/usr/bin/env bash
# Read current PR policy immediately before a privileged decision. A blocked
# PR loses any pending merge request. Print only true/false for the caller;
# incomplete evidence or failed revocation exits 2 and authorizes nothing.
set -euo pipefail

refuse() {
  echo "::error::Unable to establish current auto-merge policy." >&2
  exit 2
}
[[ $# == 4 ]] || refuse
repository=$1 number=$2 expected_head=$3 decision=$4
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
  $number =~ ^[1-9][0-9]*$ && $expected_head =~ ^[a-f0-9]{40}$ &&
  $expected_head != 0000000000000000000000000000000000000000 &&
  ($decision == approve || $decision == arm) ]] || refuse
authors=${TRUSTED_BOT_AUTHORS-}
jq -en --argjson authors "$authors" '
  $authors | type == "array" and length > 0 and
    all(.[]; type == "string" and length > 0) and
    (unique | length) == length
' >/dev/null 2>&1 || refuse

# shellcheck disable=SC2016 # GraphQL variables are literal query parameters.
snapshot=$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){headRefOid state isDraft author{login __typename} labels(first:100){totalCount nodes{name} pageInfo{hasNextPage}}}}}' \
  -f owner="${repository%%/*}" -f name="${repository#*/}" -F number="$number") || refuse
jq -e '
  ((has("errors") | not) or (.errors | type == "array" and length == 0)) and
  (.data.repository.pullRequest as $p |
    ($p.headRefOid | type == "string" and test("^[a-f0-9]{40}$")) and
    ($p.state == "OPEN" or $p.state == "CLOSED" or $p.state == "MERGED") and
    ($p.isDraft | type == "boolean") and
    ($p.author.login | type == "string" and length > 0) and
    ($p.author.__typename | type == "string" and length > 0) and
    ($p.labels.totalCount | type == "number" and floor == . and . >= 0) and
    ($p.labels.nodes | type == "array" and all(.[]; .name | type == "string" and length > 0)) and
    $p.labels.pageInfo.hasNextPage == false and
    ($p.labels.nodes | length) == $p.labels.totalCount and
    ([$p.labels.nodes[].name] | unique | length) == $p.labels.totalCount)
' <<<"$snapshot" >/dev/null 2>&1 || refuse

if jq -e 'any(.data.repository.pullRequest.labels.nodes[]; .name == "blocked")' \
  <<<"$snapshot" >/dev/null; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # The denial is current even if the head moved after the event. No head or
  # new authorization may override a currently observed parking label.
  bash "$here/disarm-auto-merge.sh" "$repository" "$number" >&2 || refuse
  printf 'false\n'
  exit 0
fi

author=$(jq -r '.data.repository.pullRequest.author |
  if .__typename == "Bot" and (.login | endswith("[bot]") | not)
  then .login + "[bot]" else .login end' <<<"$snapshot")
if ! jq -e --arg head "$expected_head" --arg author "$author" --argjson authors "$authors" '
  .data.repository.pullRequest |
    .state == "OPEN" and .isDraft == false and .headRefOid == $head and
    .author.__typename == "Bot" and
    ($authors | index($author)) != null
' <<<"$snapshot" >/dev/null; then
  printf 'false\n'
  exit 0
fi

# Renovate resolves inherited package rules itself. Preserve its legitimate
# native requests; this workflow must never create one on Renovate's behalf.
if [[ $decision == arm && $author == 'renovate[bot]' ]]; then
  printf 'false\n'
else
  printf 'true\n'
fi
