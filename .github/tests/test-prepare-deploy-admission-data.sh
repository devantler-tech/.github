#!/usr/bin/env bash
# Exercise the real bare-object reader; only its public network transport is replaced.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
reader="$repo_root/.github/scripts/prepare-deploy-admission-data.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "deploy admission data test: $*" >&2
  exit 1
}
[[ -f "$reader" ]] || fail 'reviewed bare-object reader is missing'
real_git="$(command -v git)"
mkdir -p "$scratch/source/deploy" "$scratch/source/scripts" "$scratch/bin"
git init --quiet --initial-branch=main "$scratch/source"
git -C "$scratch/source" config user.name 'Admission fixture'
git -C "$scratch/source" config user.email fixture@example.invalid
git -C "$scratch/source" config commit.gpgsign false
printf 'base manifests\n' >"$scratch/source/deploy/resource.yaml"
printf '#!/bin/sh\nexit 99\n' >"$scratch/source/scripts/never-run.sh"
git -C "$scratch/source" add deploy/resource.yaml scripts/never-run.sh
git -C "$scratch/source" commit --quiet -m 'fix: fixture base'
git -C "$scratch/source" switch --quiet -c feature
printf 'candidate manifests\n' >"$scratch/source/deploy/resource.yaml"
# Archive attributes must not hide a manifest from the data reader.
printf 'resource.yaml export-ignore\n' >"$scratch/source/deploy/.gitattributes"
git -C "$scratch/source" add deploy/resource.yaml deploy/.gitattributes
git -C "$scratch/source" commit --quiet -m 'fix: fixture candidate'
head_sha="$(git -C "$scratch/source" rev-parse HEAD)"
git -C "$scratch/source" switch --quiet main
printf 'unrelated base update\n' >"$scratch/source/README.md"
git -C "$scratch/source" add README.md
git -C "$scratch/source" commit --quiet -m 'docs: advance base'
base_sha="$(git -C "$scratch/source" rev-parse HEAD)"
git -C "$scratch/source" merge --quiet --no-ff feature -m 'Merge fixture candidate'
candidate_sha="$(git -C "$scratch/source" rev-parse HEAD)"
ln -s /etc/passwd "$scratch/source/deploy/unsafe-link"
git -C "$scratch/source" add deploy/unsafe-link
git -C "$scratch/source" commit --quiet -m 'test: unsafe symlink'
symlink_sha="$(git -C "$scratch/source" rev-parse HEAD)"
git -C "$scratch/source" update-index --add --cacheinfo "160000,$head_sha,deploy/unsafe-gitlink"
git -C "$scratch/source" commit --quiet -m 'test: unsafe gitlink'
gitlink_sha="$(git -C "$scratch/source" rev-parse HEAD)"
git -C "$scratch/source" rm --quiet deploy/unsafe-link
git -C "$scratch/source" commit --quiet -m 'test: isolated gitlink'
gitlink_sha="$(git -C "$scratch/source" rev-parse HEAD)"

# The shim leaves every real Git operation intact except one closed URL's
# transport. This fixture cannot accidentally fetch a real repository.
cat >"$scratch/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
is_fetch=false
for arg in "$@"; do [[ "$arg" != fetch ]] || is_fetch=true; done
if "$is_fetch"; then
  [[ "$*" == *'--no-write-fetch-head'* && "$*" == *'--no-recurse-submodules'* && "$*" == *'--no-tags'* ]] || exit 91
  printf 'fetch\n' >>"$TRACE"
  [[ "$MODE" != fetch-failed ]] || { echo 'injected object transport failure' >&2; exit 72; }
  found=false
  for index in "${!args[@]}"; do
    case "${args[$index]}" in
      https://github.com/devantler-tech/.github.git) args[$index]="$FIXTURE_ORIGIN"; found=true ;;
      protocol.file.allow=never) args[$index]=protocol.file.allow=always ;;
    esac
  done
  "$found" || exit 92
fi
exec "$REAL_GIT" "${args[@]}"
GIT
chmod +x "$scratch/bin/git"

for mode in valid symlink gitlink fetch-failed missing-candidate mutable-base disconnected-candidate; do
  mkdir -p "$scratch/$mode"
  : >"$scratch/$mode/output"
  : >"$scratch/$mode/trace"
  candidate="$candidate_sha" base="$base_sha"
  case "$mode" in
  symlink) candidate="$symlink_sha" ;;
  gitlink) candidate="$gitlink_sha" ;;
  missing-candidate) candidate=ffffffffffffffffffffffffffffffffffffffff ;;
  mutable-base) base=main ;;
  disconnected-candidate) candidate="$base_sha" ;;
  esac
  status=0
  env -i PATH="$scratch/bin:$PATH" REAL_GIT="$real_git" FIXTURE_ORIGIN="$scratch/source" \
    MODE="$mode" TRACE="$scratch/$mode/trace" RUNNER_TEMP="$scratch/$mode" \
    GITHUB_OUTPUT="$scratch/$mode/output" BASE_SHA="$base" HEAD_SHA="$head_sha" CANDIDATE_SHA="$candidate" \
    bash "$reader" >"$scratch/$mode/log" 2>&1 || status=$?
  if [[ "$mode" == valid ]]; then
    [[ "$status" == 0 ]] || {
      cat "$scratch/$mode/log" >&2
      fail 'valid object history was refused'
    }
    history="$(sed -n 's/^history=//p' "$scratch/$mode/output")"
    base_deploy="$(sed -n 's/^base-deploy=//p' "$scratch/$mode/output")"
    candidate_deploy="$(sed -n 's/^candidate-deploy=//p' "$scratch/$mode/output")"
    [[ "$(git --git-dir="$history" rev-parse --is-bare-repository)" == true ]] || fail 'history is not bare'
    [[ ! -e "$history/FETCH_HEAD" && ! -e "$history/index" ]] || fail 'candidate checkout state was created'
    [[ "$(cat "$base_deploy/resource.yaml")" == 'base manifests' ]] || fail 'merge-base data is wrong'
    [[ "$(cat "$candidate_deploy/resource.yaml")" == 'candidate manifests' ]] || fail 'candidate data is wrong or attributes hid it'
    [[ ! -e "${candidate_deploy%/deploy}/scripts" && ! -e "${candidate_deploy%/deploy}/.git" ]] || fail 'candidate code was materialized'
    [[ "$(git --git-dir="$history" log --format=%s "$base_sha..$head_sha")" == 'fix: fixture candidate' ]] || fail 'complete PR history is unavailable'
    [[ "$(git --git-dir="$history" diff --name-only "$base_sha...$head_sha" | wc -l | tr -d ' ')" == 2 ]] || fail 'complete changed-path data is unavailable'
  else
    [[ "$status" != 0 ]] || fail "$mode was admitted"
    [[ ! -s "$scratch/$mode/output" ]] || fail "$mode published partial outputs"
    [[ "$(find "$scratch/$mode" -type f -name resource.yaml | wc -l | tr -d ' ')" == 0 ]] || fail "$mode left candidate data after refusal"
    case "$mode" in
    symlink | gitlink) grep -q 'only ordinary deploy files' "$scratch/$mode/log" || fail "$mode failed for an unrelated reason" ;;
    fetch-failed) grep -q 'injected object transport failure' "$scratch/$mode/log" || fail 'fetch failure was not exercised' ;;
    mutable-base) [[ ! -s "$scratch/$mode/trace" ]] || fail 'mutable identity reached transport' ;;
    disconnected-candidate) grep -q 'does not contain the GitHub base and head' "$scratch/$mode/log" || fail 'ancestry refusal was not exercised' ;;
    esac
  fi
done
echo 'deploy admission data: real Git history, deploy-only materialization and six refusal controls passed'
