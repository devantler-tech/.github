#!/usr/bin/env bash
# Execute shipped release decisions against local Git remotes, without auth.
set -euo pipefail
root="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
workflow="${1:-$root/.github/workflows/create-release.yaml}"
config="${2:-$root/.releaserc}"
disabled="${DISABLE_ISSUE_SIDE_EFFECTS:-false}"
warning_enabled="${WARN_MISSING_BREAKING_BANG:-false}"
[[ "$disabled" == true || "$disabled" == false ]] || {
  echo 'invalid hook setting' >&2
  exit 1
}
[[ "$warning_enabled" == true || "$warning_enabled" == false ]] || {
  echo 'invalid warning setting' >&2
  exit 1
}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# GitHub publication requires live authentication, even during dry-run. Keep
# its production declaration required, but omit only that publisher from these
# offline decision fixtures. Native release/readback proves publication.
jq -e '
  def name: if type == "array" then .[0] else . end;
  [.plugins[] | name] as $names |
  ($names | index("@semantic-release/github")) != null and
  ($names | index("@semantic-release/release-notes-generator")) != null and
  all($names[]; . == "@semantic-release/commit-analyzer" or
    . == "@semantic-release/release-notes-generator" or . == "@semantic-release/github")
' "$config" >/dev/null || {
  echo 'FAIL: production release requires notes and GitHub publishing; unknown fixture plugins are unsupported' >&2
  exit 1
}
jq '.plugins |= map(select((if type == "array" then .[0] else . end) != "@semantic-release/github"))' \
  "$config" >"$work/decisions.json"
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
yq -r '.jobs.release.steps[] | select(.id == "breaking-bang-guard") | .run' "$workflow" >"$work/guard.sh"
[[ -s "$work/guard.sh" ]] || { echo 'FAIL: missing shipped warning guard' >&2; exit 1; }
mkdir "$work/tool-error"
printf '#!/usr/bin/env bash\nexit 99\n' >"$work/tool-error/jq"
chmod +x "$work/tool-error/jq"

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
  cp "$work/decisions.json" "$repo/.releaserc"
  expected_warnings=0
  guard_enabled="$warning_enabled"
  guard_path="$PATH"
  case "$name" in
    warning-*)
      jq '(.plugins[] | select(type == "array" and .[0] == "@semantic-release/commit-analyzer") | .[1].parserOpts) |= del(.breakingHeaderPattern)' \
        "$work/decisions.json" >"$repo/.releaserc"
      case "$name" in
        warning-missing) [[ "$guard_enabled" != true ]] || expected_warnings=1 ;;
        warning-disabled) guard_enabled=false ;;
        warning-unsupported) printf '{}\n' >"$repo/.releaserc.yaml" ;;
        warning-tool-error) guard_path="$work/tool-error:$PATH" ;;
      esac
      ;;
  esac
  fixture_git -C "$repo" add .releaserc
  fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet -m 'chore: baseline'
  fixture_git -C "$repo" -c tag.gpgsign=false tag v1.2.3
  fixture_git -C "$repo" -c commit.gpgsign=false commit --quiet --allow-empty -m "$message"
  fixture_git -C "$repo" remote add origin "file://$remote"
  fixture_git -C "$repo" push --quiet origin main --tags
  before="$(fixture_git -C "$repo" show-ref)"
  remote_before="$(fixture_git --git-dir="$remote" show-ref)"
  config_before="$(fixture_git -C "$repo" hash-object .releaserc)"
  unsupported_before=''
  [[ ! -e "$repo/.releaserc.yaml" ]] || unsupported_before="$(fixture_git -C "$repo" hash-object .releaserc.yaml)"
  tree_before="$(fixture_git -C "$repo" status --porcelain --untracked-files=all)"
  : >"$work/guard-output"
  if [[ "$guard_enabled" == true ]]; then
    # Match the production continue-on-error step. A tool error must not gate release.
    (cd "$repo" && env -i PATH="$guard_path" bash -eo pipefail "$work/guard.sh") >"$work/guard-output" 2>&1 || true
  fi
  warnings="$(awk '/^::warning::/ { count++ } END { print count+0 }' "$work/guard-output")"
  [[ "$warnings" == "$expected_warnings" ]] || {
    cat "$work/guard-output" >&2
    echo "FAIL: $name expected $expected_warnings warning(s)" >&2
    exit 1
  }
  if [[ "$expected_warnings" == 1 ]]; then
    grep -qF '.releaserc: @semantic-release/commit-analyzer does not declare parserOpts.breakingHeaderPattern.' "$work/guard-output"
    cat "$work/guard-output"
  fi
  [[ "$(fixture_git -C "$repo" hash-object .releaserc)" == "$config_before" &&
     "$(fixture_git -C "$repo" status --porcelain --untracked-files=all)" == "$tree_before" ]] || {
    echo "FAIL: $name warning guard changed consumer files" >&2
    exit 1
  }
  [[ -z "$unsupported_before" || "$(fixture_git -C "$repo" hash-object .releaserc.yaml)" == "$unsupported_before" ]] || {
    echo "FAIL: $name warning guard changed unsupported configuration" >&2
    exit 1
  }
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
  [[ "$(fixture_git -C "$repo" hash-object .releaserc)" == "$config_before" &&
     "$(fixture_git -C "$repo" status --porcelain --untracked-files=all)" == "$tree_before" ]] || {
    echo "FAIL: $name dry-run changed consumer files" >&2
    exit 1
  }
  [[ -z "$unsupported_before" || "$(fixture_git -C "$repo" hash-object .releaserc.yaml)" == "$unsupported_before" ]] || {
    echo "FAIL: $name dry-run changed unsupported configuration" >&2
    exit 1
  }
  cases=$((cases + 1))
  echo "PASS: $name -> $expected; warning=$warnings; files and refs unchanged"
done <<'CASES'
fix	fix: repair workflow	1.2.4
perf	perf: accelerate workflow	1.2.4
revert	revert: remove faulty change	1.2.4
feature	feat: add workflow	1.3.0
breaking	feat!: require new configuration	2.0.0
scoped-breaking	fix(release)!: require new configuration	2.0.0
docs	docs: clarify usage	none
warning-missing	fix: exercise missing breaking header	1.2.4
warning-disabled	fix: exercise disabled diagnostic	1.2.4
warning-unsupported	fix: exercise unsupported diagnostic configuration	1.2.4
warning-tool-error	fix: exercise diagnostic tool failure	1.2.4
CASES
echo "PASS: $cases actual release decisions; warning enabled=$warning_enabled; issue-hook suppression=$disabled; no credentials"
