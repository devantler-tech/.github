#!/usr/bin/env bash
# Read immutable PR objects without checking out any candidate implementation.
set -euo pipefail
umask 077
fail() {
  echo "deploy admission data: $*" >&2
  exit 2
}
for identity in BASE_SHA HEAD_SHA CANDIDATE_SHA; do
  [[ "${!identity:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'complete immutable GitHub identities are required'
done
[[ -d "${RUNNER_TEMP:-}" && -f "${GITHUB_OUTPUT:-}" ]] || fail 'runner temporary storage and output are required'
[[ "$RUNNER_TEMP" != *$'\n'* && "$RUNNER_TEMP" != *$'\r'* ]] || fail 'invalid runner temporary path'
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0
root="$(mktemp -d "$RUNNER_TEMP/deploy-admission.XXXXXX")"
complete=false
# Refusal leaves neither published paths nor partial manifest data behind.
cleanup() { if ! "$complete"; then rm -rf "$root"; fi; }
trap cleanup EXIT
history="$root/history.git"
git init --quiet --bare --template= "$history"
# No worktree, hooks, credential helper, submodules or mutable refs. Full history
# is needed for the release contract and deletion comparison, not an API page.
git -c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=never \
  -c protocol.ext.allow=never --git-dir="$history" fetch --quiet --no-tags \
  --no-recurse-submodules --no-write-fetch-head --no-auto-gc \
  https://github.com/devantler-tech/.github.git \
  "$BASE_SHA:refs/admission/base" "$HEAD_SHA:refs/admission/head" "$CANDIDATE_SHA:refs/admission/candidate"
for reference in base head candidate; do
  case "$reference" in
  base) expected="$BASE_SHA" ;;
  head) expected="$HEAD_SHA" ;;
  candidate) expected="$CANDIDATE_SHA" ;;
  esac
  [[ "$(git --git-dir="$history" rev-parse "refs/admission/$reference^{commit}")" == "$expected" ]] || fail 'fetched object identity differs from GitHub'
done
if ! git --git-dir="$history" merge-base --is-ancestor "$BASE_SHA" "$CANDIDATE_SHA" ||
  ! git --git-dir="$history" merge-base --is-ancestor "$HEAD_SHA" "$CANDIDATE_SHA"; then
  fail 'candidate does not contain the GitHub base and head'
fi
merge_base="$(git --git-dir="$history" merge-base "$BASE_SHA" "$HEAD_SHA")"

# Validate the complete tree first, then write only ordinary blobs under deploy/.
# cat-file deliberately ignores candidate .gitattributes (unlike git archive).
materialize_deploy() {
  local revision="$1" destination="$2" listing="$3" entry metadata path mode kind object count=0
  [[ "$(git --git-dir="$history" cat-file -t "$revision:deploy")" == tree ]] || fail 'deploy directory is missing'
  git --git-dir="$history" ls-tree --full-tree -rz "$revision" -- deploy/ >"$listing"
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}" path="${entry#*$'\t'}"
    read -r mode kind object <<<"$metadata"
    [[ ("$mode" == 100644 || "$mode" == 100755) && "$kind" == blob && "$object" =~ ^[0-9a-f]{40}$ &&
      "$path" == deploy/* && "/$path/" != *'/../'* && "/$path/" != *'/./'* &&
      "/$path/" != *'//'* && "/$path/" != *'/.git/'* ]] || fail 'only ordinary deploy files may be materialized'
    count=$((count + 1))
  done <"$listing"
  [[ "$count" -gt 0 ]] || fail 'deploy tree is empty'
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}" path="${entry#*$'\t'}"
    read -r mode kind object <<<"$metadata"
    mkdir -p -- "$destination/${path%/*}"
    git --git-dir="$history" cat-file blob "$object" >"$destination/$path"
  done <"$listing"
}
materialize_deploy "$merge_base" "$root/base" "$root/base-tree"
materialize_deploy "$CANDIDATE_SHA" "$root/candidate" "$root/candidate-tree"
printf 'history=%s\nbase-deploy=%s\ncandidate-deploy=%s\n' \
  "$history" "$root/base/deploy" "$root/candidate/deploy" >>"$GITHUB_OUTPUT"
complete=true
