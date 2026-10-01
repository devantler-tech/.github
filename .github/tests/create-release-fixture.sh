#!/usr/bin/env bash
# Execute the shipped release command/config against local Git remotes, without auth.
set -euo pipefail
root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
workflow="${1:-$root/.github/workflows/create-release.yaml}"
config="${2:-$root/.releaserc}"
disabled="${DISABLE_ISSUE_SIDE_EFFECTS:-false}"
[[ "$disabled" == true || "$disabled" == false ]] || {
  echo 'invalid hook setting' >&2
  exit 1
}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
run="$(yq -r '.jobs.release.steps[] | select(.name == "🎉 Release") | .run' "$workflow")"
hooks="\${{ inputs.disable-issue-side-effects && '--success false --fail false' || '' }}"
dry="\${{ inputs.dry-run && '--dry-run' || '' }}"
[[ "$run" == "npx semantic-release@25.0.3 $hooks $dry" ]] || {
  echo 'FAIL: unsupported shipped release command' >&2
  exit 1
}
flags=''
[[ "$disabled" == false ]] || flags='--success false --fail false'
run="${run//"$hooks"/$flags}"
run="${run//"$dry"/--dry-run}"
read -r -a command_parts <<<"$run"
cache="$(npm config get cache)"
: >"$work/npm-user.conf"
: >"$work/npm-global.conf"

# Fixture setup and assertions must ignore ambient Git paths, config, templates and hooks too.
fixture_git() {
  env -i PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_ALLOW_PROTOCOL=file git -c core.hooksPath=/dev/null -c init.templateDir= "$@"
}
cases=0
while IFS=$'\t' read -r name message expected; do
  repo="$work/$name"
  remote="$work/$name.git"
  fixture_git -c init.defaultBranch=main init --quiet --bare "$remote"
  fixture_git -c init.defaultBranch=main init --quiet "$repo"
  fixture_git -C "$repo" config user.name 'Release fixture'
  fixture_git -C "$repo" config user.email 'fixture@example.invalid'
  cp "$config" "$repo/.releaserc"
  fixture_git -C "$repo" add .releaserc
  fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet -m 'chore: baseline'
  fixture_git -C "$repo" -c tag.gpgsign=false tag v1.2.3
  fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet --allow-empty -m "$message"
  fixture_git -C "$repo" remote add origin "file://$remote"
  fixture_git -C "$repo" push --quiet origin main --tags
  before="$(fixture_git -C "$repo" show-ref)"
  remote_before="$(fixture_git --git-dir="$remote" show-ref)"
  if ! (cd "$repo" && env -i PATH="$PATH" npm_config_cache="$cache" npm_config_offline=true npm_config_yes=true \
    npm_config_userconfig="$work/npm-user.conf" npm_config_globalconfig="$work/npm-global.conf" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 GIT_ALLOW_PROTOCOL=file \
    "${command_parts[@]}" --no-ci --repository-url "file://$remote") >"$work/output" 2>&1; then
    cat "$work/output" >&2
    echo "FAIL: $name release command failed" >&2
    exit 1
  fi
  if [[ "$expected" == none ]]; then
    grep -qF 'no new version is released' "$work/output" || {
      cat "$work/output" >&2
      echo "FAIL: $name expected no release" >&2
      exit 1
    }
  else
    grep -qF "The next release version is $expected" "$work/output" || {
      cat "$work/output" >&2
      echo "FAIL: $name expected $expected" >&2
      exit 1
    }
  fi
  [[ "$(fixture_git -C "$repo" show-ref)" == "$before" && "$(fixture_git --git-dir="$remote" show-ref)" == "$remote_before" ]] || {
    echo "FAIL: $name dry-run changed refs" >&2
    exit 1
  }
  cases=$((cases + 1))
  echo "PASS: $name -> $expected; local and bare refs unchanged"
done <<'CASES'
fix	fix: repair workflow	1.2.4
perf	perf: accelerate workflow	1.2.4
revert	revert: remove faulty change	1.2.4
feature	feat: add workflow	1.3.0
breaking	feat!: require new configuration	2.0.0
scoped-breaking	fix(release)!: require new configuration	2.0.0
docs	docs: clarify usage	none
CASES
echo "PASS: $cases actual release decisions; issue-hook suppression=$disabled; no credentials"
