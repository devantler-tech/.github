#!/usr/bin/env bash
# Hold listed skills at a reviewed upstream commit before `gh skill update --all` runs.
#
# Each line of the pins text (read from stdin) names an installed skill directory and a full
# 40-character upstream commit:
#
#   .agents/skills/git-commit 0123456789abcdef0123456789abcdef01234567 # until devantler-tech/platform#5224
#
# Blank lines and lines starting with `#` are ignored, and a ` #` comment may follow the commit; use
# it to name the issue that tracks removing the pin. Every line is validated, and every pin installed
# into a staging directory, before any skill changes, so one bad line or failed install changes
# nothing. Each skill is reinstalled from the upstream repository and path in its own `github-*`
# metadata with `gh skill install --pin <commit>`, which records `metadata.github-pinned`, so the later
# `gh skill update --all` skips it. The skill directory is replaced as a whole: it ends up holding
# exactly the upstream content of that commit. A skill already pinned to the requested commit is left
# alone.
#
# Usage: pin-skills.sh <dir> [--dry-run] < pins
#   <dir>      every pinned skill directory must lie under this directory
#   --dry-run  validate and report the pins without changing any file
set -euo pipefail

dir=${1:-}
dry_run=false
case "${2:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "::error::Unknown option: $2"; exit 1 ;;
esac
if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "::error::Directory not found: ${dir:-<empty>}"
  exit 1
fi
root=$(cd "$dir" && pwd -P)

if ! yq_help=$(yq --help 2>/dev/null) || ! grep -q -- '--front-matter' <<< "$yq_help"; then
  echo "::error::mikefarah yq v4 with --front-matter support is required on PATH to pin skills."
  exit 1
fi

retry() {
  if [[ -n "${GITHUB_ACTION_PATH:-}" ]]; then
    bash "${GITHUB_ACTION_PATH}/../../.scripts/retry.sh" "$@"
  else
    "$@"
  fi
}

# ── Validate every line first ──
skills=() repos=() paths=() commits=() currents=() seen=$'\n'
errors=0 n=0
reject() { echo "::error::pins line $n ($1): $2"; errors=$((errors + 1)); }
while IFS= read -r raw || [[ -n "$raw" ]]; do
  n=$((n + 1))
  line=${raw%%$'\r'}
  # Drop a trailing ` #` comment, then surrounding whitespace.
  line=$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$line")
  [[ -z "$line" || "$line" == \#* ]] && continue

  read -r skill commit extra <<< "$line"
  if [[ -z "${commit:-}" || -n "${extra:-}" ]]; then
    reject "$line" "expected '<skill-dir> <40-character commit>'"
    continue
  fi
  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    reject "$line" "'$commit' is not a full 40-character lowercase commit SHA"
    continue
  fi
  if [[ ! -f "$skill/SKILL.md" ]]; then
    reject "$line" "'$skill' is not an installed skill directory (no SKILL.md)"
    continue
  fi
  abs=$(cd "$skill" && pwd -P)
  if [[ "$abs" == "$root" || "$abs" != "$root/"* ]]; then
    reject "$line" "'$skill' is not a skill directory under '$dir'"
    continue
  fi
  if [[ "$seen" == *$'\n'"$abs"$'\n'* ]]; then
    reject "$line" "'$skill' is pinned more than once"
    continue
  fi
  seen+="$abs"$'\n'
  # yq's diagnostics stay on stderr, so they never become part of a value.
  if ! repo_url=$(yq --front-matter=extract '.metadata."github-repo" // ""' "$skill/SKILL.md") ||
    ! path=$(yq --front-matter=extract '.metadata."github-path" // ""' "$skill/SKILL.md") ||
    ! current=$(yq --front-matter=extract '.metadata."github-pinned" // ""' "$skill/SKILL.md"); then
    reject "$line" "cannot read the github-* metadata of '$skill/SKILL.md'"
    continue
  fi
  if [[ ! "$repo_url" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
    reject "$line" "'$skill/SKILL.md' has no github-repo of the form https://github.com/<owner>/<repo>"
    continue
  fi
  repo=${BASH_REMATCH[1]}
  if [[ -z "$path" || "$path" == "null" || "$path" == "." || "$path" == /* ||
    "/$path/" == */../* || "/$path/" == */./* ]]; then
    reject "$line" "'$skill/SKILL.md' has no usable github-path"
    continue
  fi
  skills+=("$abs") repos+=("$repo") paths+=("$path") commits+=("$commit") currents+=("$current")
done

if [[ "$errors" -ne 0 ]]; then
  echo "::error::$errors invalid pin line(s); no skill was pinned."
  exit 1
fi
if [[ ${#skills[@]} -eq 0 ]]; then
  exit 0
fi

# ── Stage every pin, then put them all in place ──
# Nothing in <dir> changes until every listed skill has been installed and checked, so a failed pin
# leaves every skill as it was.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
staged=() targets=() labels=()
for i in "${!skills[@]}"; do
  skill=${skills[$i]} repo=${repos[$i]} path=${paths[$i]} commit=${commits[$i]}
  label="$dir/${skill#"$root"/} to $repo@$commit"
  if [[ "${currents[$i]}" == "$commit" ]]; then
    # `gh skill update --all` already skips it; reinstalling would only add a network round trip.
    echo "Already pinned: $label"
    continue
  fi
  if [[ "$dry_run" == true ]]; then
    echo "Would pin: $label"
    continue
  fi
  stage="$work/$i"
  # Each attempt starts from an empty directory, so a failed attempt leaves nothing for a retry to
  # trip over or merge with. Name the SKILL.md path so the CLI resolves this exact skill.
  # shellcheck disable=SC2016 # expanded by the inner shell
  if ! retry bash -c 'rm -rf "$1" && mkdir -p "$1" && gh skill install "$2" "$3" --pin "$4" --dir "$1" </dev/null' \
    _ "$stage" "$repo" "${path%/}/SKILL.md" "$commit"; then
    echo "::error::Installing $repo $path at $commit failed; no skill was pinned."
    exit 1
  fi
  installed=()
  while IFS= read -r -d '' md; do installed+=("$(dirname "$md")"); done \
    < <(find "$stage" -mindepth 2 -maxdepth 2 -type f -name SKILL.md -print0)
  if [[ ${#installed[@]} -ne 1 ]]; then
    echo "::error::Expected one skill from $repo $path at $commit, got ${#installed[@]}; no skill was pinned."
    exit 1
  fi
  pinned=$(yq --front-matter=extract '.metadata."github-pinned" // ""' "${installed[0]}/SKILL.md")
  if [[ "$pinned" != "$commit" ]]; then
    echo "::error::$repo $path installed without github-pinned: $commit (got '${pinned}'); no skill was pinned."
    exit 1
  fi
  staged+=("${installed[0]}") targets+=("$skill") labels+=("$label")
done

for i in "${!staged[@]}"; do
  target=${targets[$i]}
  # Keep the old directory until the new one is in place, so a failed move cannot lose the skill.
  old="$work/old-$i"
  mv "$target" "$old"
  if ! mv "${staged[$i]}" "$target"; then
    rm -rf "$target"
    mv "$old" "$target"
    echo "::error::Could not move the pinned ${labels[$i]} into place; it was restored."
    exit 1
  fi
  echo "Pinned: ${labels[$i]}"
done
