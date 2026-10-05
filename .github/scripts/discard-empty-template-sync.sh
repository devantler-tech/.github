#!/usr/bin/env bash

# Discard a template-sync pull request that would change nothing (#467).
#
# The sync action pushes its commit and opens the pull request before the signing helper runs.
# When the template lags this repository on a catalogue pin, the signing helper puts this
# repository's newer line back, and the result can equal the base: the pull request then has no
# changed files (wedding-app#377, ascoachingogvaner#280). The signing helper calls this instead of
# signing such a commit.
#
# It closes the pull request this run opened and moves the generated branch back onto the base
# commit. The branch is kept on purpose: the sync action skips a template commit whose branch
# already exists, so the same empty pull request is not reopened on every scheduled run. A new
# template commit gets a new branch name and syncs normally.
#
# It touches only the branch this run generated, at the commit this run pushed. stdout is the one
# word `discarded`.

set -euo pipefail

fail() {
  echo "template-sync empty discard: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 --base-sha <sha> --branch-prefix <prefix> --tree <tree-sha>" >&2
  exit 2
}

base_sha=""
branch_prefix=""
tree_sha=""
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
    --tree)
      [[ $# -ge 2 ]] || usage
      tree_sha="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail "base sha is not a full commit oid"
[[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]] || fail "tree sha is not a full tree oid"
[[ "$branch_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "branch prefix is unsafe"
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY is unsafe"
command -v gh >/dev/null || fail "gh is unavailable"
command -v jq >/dev/null || fail "jq is unavailable"

# Everything named below must be what this run generated, and the proposal must really be empty.
base_tree="$(git rev-parse "${base_sha}^{tree}")" || fail "could not read the base tree"
[[ "$tree_sha" == "$base_tree" ]] || fail "the proposed tree differs from the base; refusing to discard a real sync"
current_sha="$(git rev-parse HEAD)" || fail "could not read the caller checkout head"
[[ "$current_sha" != "$base_sha" ]] || fail "no sync commit was created; nothing to discard"
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

note="This template sync would change no files: what the template proposes is already here, or is older than what this repository uses. The pull request was closed automatically. Its branch is kept so the same template commit is not proposed again."
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

# Keep the branch as the marker, but without the unsigned sync commit on it.
moved="$(jq -n --arg sha "$base_sha" '{sha:$sha,force:true}' |
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/git/refs/heads/${branch}" --input -)" ||
  fail "could not move the generated branch $branch back onto the base"
[[ "$(jq -r '.object.sha // ""' <<<"$moved")" == "$base_sha" ]] ||
  fail "the generated branch $branch did not report the base commit"
echo "Moved $branch back onto the base; it stays as the marker for this template commit." >&2
echo discarded
