#!/usr/bin/env bash

set -euo pipefail

# Usage: validate-release-contract.sh <pr_title> [<head_commit_count> <first_commit_subject>]
#
# Reads the changed paths as a NUL-separated list on stdin and refuses a deploy/
# change whose squash subject semantic-release would not release.
#
# The subject checked is the one GitHub will ACTUALLY squash under. This
# repository sets squash_merge_commit_title = COMMIT_OR_PR_TITLE, so a branch
# carrying exactly one commit lands under THAT COMMIT'S subject and the pull
# request title is never consulted; a multi-commit branch falls back to the
# title. Checking the title unconditionally therefore passes a deploy/ change
# that is then never published, because deploy/ publishes only on a v* tag and
# semantic-release cuts none for a non-releasing subject. That is not
# hypothetical: #169 was authored `chore(github): archive doggy-countdown`,
# retitled to a `feat:` to clear this guard, merged green under its unchanged
# chore: commit subject, and cut no release — so the archived-repository CR it
# added was never published (#170).
#
# The commit count and subject are optional so an existing caller passing only a
# title keeps its previous behaviour.

title="${1:-}"
head_commit_count="${2:-}"
first_commit_subject="${3:-}"
release_title='^(feat|fix|perf|revert)(\([[:alnum:]_.-]+\))?!?: .+'
breaking_title='^[a-z]+(\([[:alnum:]_.-]+\))?!: .+'
deploy_changed=false

[[ -n "$title" ]] || {
  echo "release-contract: pull-request title is required" >&2
  exit 1
}
while IFS= read -r -d '' path; do
  if [[ "$path" == deploy/* ]]; then
    deploy_changed=true
  fi
done

if [[ "$deploy_changed" == false ]]; then
  echo "release-contract: OK — no deploy/ artifact change"
  exit 0
fi

# Which subject will land: the lone commit's when there is exactly one, else the
# pull-request title. Resolved only once a deploy/ change is established, so the
# non-artifact exemption above stays reachable regardless of what was passed.
subject="$title"
subject_source="pull-request title"
if [[ "$head_commit_count" == 1 ]]; then
  # A one-commit branch squashes under that commit, so an unreadable subject
  # leaves the guard with nothing to judge. Fail closed and say so: falling back
  # to the title would silently restore the very hole this guard closes, and the
  # likeliest cause is infrastructural (a shallow checkout, or a base..head range
  # that resolved to nothing) rather than a badly-typed subject.
  [[ -n "$first_commit_subject" ]] || {
    echo "release-contract: this branch carries ONE commit but its subject could not be read; refusing to fall back to the pull-request title, which GitHub will not use (check the checkout depth and the BASE_SHA..HEAD_SHA range)" >&2
    exit 1
  }
  subject="$first_commit_subject"
  subject_source="single-commit subject"
fi

if [[ "$subject" =~ $release_title || "$subject" =~ $breaking_title ]]; then
  echo "release-contract: OK — deploy/ change has a release-driving $subject_source"
  exit 0
fi

echo "release-contract: deploy/ changes require a release-driving squash subject (fix, feat, perf, revert, or a breaking ! type); got '$subject' from the $subject_source" >&2
if [[ "$subject_source" == "single-commit subject" ]]; then
  echo "release-contract: this branch carries ONE commit, so GitHub squashes under its subject and the pull-request title is ignored — amend the commit, do not retitle the pull request" >&2
fi
exit 1
