#!/usr/bin/env bash
# Native stable/default-branch decisions; deliberately excludes GitHub publication.
set -euo pipefail
root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
workflow="${1:-$root/.github/workflows/create-release.yaml}"
config="${2:-$root/.releaserc}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# Require the shipped production stack, removing only its authenticated publisher.
jq -e '.branches == ["main"] and
  ([.plugins[] | if type == "array" then .[0] else . end] ==
  ["@semantic-release/commit-analyzer","@semantic-release/release-notes-generator","@semantic-release/github"])' \
  "$config" >/dev/null || fail 'unsupported stable/default-branch release configuration'
jq '.plugins |= map(select((if type == "array" then .[0] else . end) != "@semantic-release/github"))' \
  "$config" > "$work/config.json"
run="$(yq -r '.jobs.release.steps[] | select(.name == "🎉 Release") | .run' "$workflow")"
hooks="\${{ inputs.disable-issue-side-effects && '--success false --fail false' || '' }}"
dry="\${{ inputs.dry-run && '--dry-run' || '' }}"
[[ "$run" == "npx semantic-release@25.0.3 $hooks $dry" ]] || fail 'unsupported shipped release command'
run="${run//"$hooks"/}"
run="${run//"$dry"/--dry-run}"
read -r -a command_parts <<< "$run"
cache="$(npm config get cache)"
: > "$work/npm.conf"
: > "$work/npm-global.conf"
fixture_git() {
  env -i PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_ALLOW_PROTOCOL=file git -c core.hooksPath=/dev/null -c init.templateDir= "$@"
}
decisions=0
run_decision() {
  local expected=$1 before remote_before config_before observed_notes expected_notes observed_version
  # Match the native reader's commit-note visibility, including annotated tags.
  observed_notes="$(fixture_git -C "$repo" log --no-walk --format=%N '--notes=refs/notes/semantic-release*' refs/tags/v1.2.4)"
  expected_notes=''
  [[ "$notes" != matching ]] || expected_notes='{"channels":[null]}'
  [[ "$observed_notes" == "$expected_notes" ]] || fail "$mode incorrect channel-note projection"
  before="$(fixture_git -C "$repo" show-ref)"
  remote_before="$(fixture_git --git-dir="$remote" show-ref)"
  config_before="$(fixture_git -C "$repo" hash-object .releaserc)"
  if ! (cd "$repo" && env -i PATH="$PATH" npm_config_cache="$cache" npm_config_offline=true \
    npm_config_yes=true npm_config_userconfig="$work/npm.conf" npm_config_globalconfig="$work/npm-global.conf" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 GIT_ALLOW_PROTOCOL=file \
    "${command_parts[@]}" --no-ci --repository-url "file://$remote") > "$work/output" 2>&1; then
    cat "$work/output" >&2
    fail "$mode release command failed"
  fi
  observed_version="$(sed -n 's/^.*The next release version is //p' "$work/output")"
  if [[ "$expected" == none ]]; then
    if [[ -n "$observed_version" ]] || ! grep -qF 'no new version is released' "$work/output"; then
      fail "$mode expected no release"
    fi
  else
    [[ "$observed_version" == "$expected" ]] || fail "$mode expected $expected"
  fi
  [[ "$(fixture_git -C "$repo" show-ref)" == "$before" ]] || fail "$mode changed local refs"
  [[ "$(fixture_git --git-dir="$remote" show-ref)" == "$remote_before" ]] || fail "$mode changed remote refs"
  [[ "$(fixture_git -C "$repo" rev-parse 'refs/tags/v1.2.4^{commit}')" == "$stranded" ]] || fail "$mode changed tag source"
  [[ "$(fixture_git -C "$repo" hash-object .releaserc)" == "$config_before" &&
    -z "$(fixture_git -C "$repo" status --porcelain --untracked-files=all)" ]] || fail "$mode changed consumer files"
  decisions=$((decisions + 1))
  printf 'PASS: %s -> %s; files and local/remote refs unchanged\n' "$mode" "$expected"
}
for tag_kind in lightweight annotated; do
  for notes in absent matching; do
    mode="$tag_kind-$notes"
    repo="$work/$mode"
    remote="$work/$mode.git"
    fixture_git -c init.defaultBranch=main init --quiet --bare "$remote"
    fixture_git -c init.defaultBranch=main init --quiet "$repo"
    fixture_git -C "$repo" config user.name 'Release fixture'
    fixture_git -C "$repo" config user.email 'fixture@example.invalid'
    cp "$work/config.json" "$repo/.releaserc"
    fixture_git -C "$repo" add .releaserc
    fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet -m 'chore: baseline'
    fixture_git -C "$repo" -c tag.gpgsign=false tag v1.2.3
    fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet --allow-empty -m 'fix: stranded publication'
    stranded="$(fixture_git -C "$repo" rev-parse HEAD)"
    if [[ "$tag_kind" == annotated ]]; then
      fixture_git -C "$repo" -c tag.gpgsign=false tag -a -m 'stranded stable release' v1.2.4
    else
      fixture_git -C "$repo" -c tag.gpgsign=false tag v1.2.4
    fi
    if [[ "$notes" == matching ]]; then
      fixture_git -C "$repo" -c core.notesRef=refs/notes/semantic-release-v1.2.4 notes add -m '{"channels":[null]}' "$stranded"
    fi
    fixture_git -C "$repo" remote add origin "file://$remote"
    fixture_git -C "$repo" push --quiet origin main --tags
    if [[ "$notes" == matching ]]; then
      fixture_git -C "$repo" push --quiet origin refs/notes/semantic-release-v1.2.4
    fi
    run_decision none
    fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet --allow-empty -m 'fix: subsequent change'
    fixture_git -C "$repo" push --quiet origin main
    run_decision 1.2.5
  done
done
[[ "$decisions" == 8 ]] || fail 'incomplete stable-channel matrix'
echo 'PASS: eight native stable/default-branch decisions; GitHub publication, prereleases and multiple branches not exercised'
