#!/usr/bin/env bash

# Discard a template-sync pull request that changes nothing (#467).
#
# Every consumer squash-merges its sync pull request, so the template commit never enters the
# consumer's history and the sync action cannot tell that it was already applied. Its next run
# pulls the same template commit again, ends with the base tree, and still commits, pushes and
# opens a pull request with no changed files (wedding-app#377, ascoachingogvaner#280).
#
# This helper runs right after the sync action. When the generated commit's tree equals the base
# tree, it closes the pull request the run opened and deletes the generated branch. It touches
# only the branch this run generated, at the commit this run pushed.
#
# stdout is one word the workflow reads: `none` (no sync commit), `changed` (a real sync, left
# alone) or `discarded` (the empty pull request and its branch are gone).

set -euo pipefail

fail() {
  echo "template-sync empty check: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 --base-sha <sha> --branch-prefix <prefix>" >&2
  exit 2
}

base_sha=""
branch_prefix=""
while (($#)); do
  case "$1" in
    --base-sha)
      [[ $# -ge 2 ]] || usage
      base_sha="$2"
      shift 2
      ;;
    --branch-prefix)
      [[ $# -ge 2 ]] || usage
      branch_prefix="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail "base sha is not a full commit oid"
[[ "$branch_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "branch prefix is unsafe"
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY is unsafe"
command -v gh >/dev/null || fail "gh is unavailable"
command -v jq >/dev/null || fail "jq is unavailable"

current_sha="$(git rev-parse HEAD)" || fail "could not read the caller checkout head"
if [[ "$current_sha" == "$base_sha" ]]; then
  echo "No template-sync commit was created; nothing to discard." >&2
  echo none
  exit 0
fi

base_tree="$(git rev-parse "${base_sha}^{tree}")" || fail "could not read the base tree"
current_tree="$(git rev-parse 'HEAD^{tree}')" || fail "could not read the sync commit tree"
if [[ "$current_tree" != "$base_tree" ]]; then
  echo "The sync commit changes files; the pull request is kept." >&2
  echo changed
  exit 0
fi

# From here on the run deletes things, so everything it names must be what this run generated.
branch="$(git branch --show-current)" || fail "could not read the generated branch"
[[ "$branch" == "${branch_prefix}_"* ]] ||
  fail "refusing to discard unexpected branch '$branch' (expected '${branch_prefix}_*')"
[[ "$branch" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "generated branch name is unsafe"
git merge-base --is-ancestor "$base_sha" HEAD ||
  fail "the sync commit does not descend from the workflow base sha"

ref_endpoint="repos/${GITHUB_REPOSITORY}/git/ref/heads/${branch}"
remote_ref="$(gh api "$ref_endpoint")" || fail "could not read the generated remote branch"
remote_sha="$(jq -er '.object.sha' <<<"$remote_ref")" || fail "generated remote branch response has no sha"
[[ "$remote_sha" == "$current_sha" ]] ||
  fail "generated remote branch moved after the sync action (expected $current_sha, found $remote_sha)"

owner="${GITHUB_REPOSITORY%%/*}"
pulls="$(gh api "repos/${GITHUB_REPOSITORY}/pulls?state=open&head=${owner}:${branch}&per_page=100")" ||
  fail "could not list the pull requests opened from $branch"
numbers="$(jq -er --arg sha "$current_sha" --arg branch "$branch" '
  if type != "array" then error("not a list") else . end
  | map(
      if (.head.ref == $branch and .head.sha == $sha and (.number | type) == "number")
      then .number
      else error("unexpected pull request")
      end
    )
  | .[]
' <<<"$pulls")" || {
  # jq -e also fails on an empty list, which is fine: the branch may have no pull request.
  [[ "$(jq -r 'if type == "array" then length else "invalid" end' <<<"$pulls")" == "0" ]] ||
    fail "a pull request from $branch does not match the commit this run pushed; refusing to discard"
  numbers=""
}

note="This template sync changes no files: the template commit it proposes is already applied here, so the pull request was closed and its branch deleted automatically."
while IFS= read -r number; do
  [[ -n "$number" ]] || continue
  [[ "$number" =~ ^[0-9]+$ ]] || fail "pull request number '$number' is not numeric"
  jq -n --arg body "$note" '{body:$body}' |
    gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${number}/comments" --input - >/dev/null ||
    fail "could not explain the closure on pull request #$number"
  closed="$(jq -n '{state:"closed"}' |
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/pulls/${number}" --input -)" ||
    fail "could not close pull request #$number"
  [[ "$(jq -r '.state // ""' <<<"$closed")" == "closed" ]] ||
    fail "pull request #$number did not report closed"
  echo "Closed empty template-sync pull request #$number." >&2
done <<<"$numbers"

gh api -X DELETE "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch}" >/dev/null ||
  fail "could not delete the generated branch $branch"
echo "Deleted empty template-sync branch $branch." >&2
echo discarded
