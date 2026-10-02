#!/usr/bin/env bash

# Merge the template's ignore entries into the target's ignore file before template sync
# (devantler-tech/platform-tenant-template#171).
#
# actions-template-sync restores the target's ignore file to its committed copy after pulling the
# template, and only that copy decides which paths are dropped. An entry the template adds later
# therefore never applies to a target created before it. This helper appends every template entry
# the target's list lacks and commits the result locally, so the action restores and applies the
# merged list. The commit is never pushed on its own: the action pushes it under its sync commit,
# and with an App token the signing helper folds both into one signed commit (`--pre-sync-sha`).
#
# The target's own lines are kept as they are, including entries the template does not have. A
# target keeps one template entry out with a `!<entry>` line (inert to the action, which reads
# each line as a literal pathspec).
#
# Prints the merge commit's sha on stdout when it creates one, and nothing otherwise.

set -euo pipefail

fail() {
  echo "template-sync ignore merge: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 --base-sha <sha> --source-repo <owner/repo> --ref <branch> --ignore-file <path>" >&2
  exit 2
}

base_sha=""
source_repo=""
ref=""
ignore_file=""
while (($#)); do
  case "$1" in
    --base-sha | --source-repo | --ref | --ignore-file)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --base-sha) base_sha="$2" ;;
        --source-repo) source_repo="$2" ;;
        --ref) ref="$2" ;;
        --ignore-file) ignore_file="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail "base sha is not a full commit oid"
[[ "$source_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "source repository is unsafe"
[[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$ref" != *..* ]] || fail "template ref is unsafe"
[[ "$ignore_file" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$ignore_file" != *..* ]] ||
  fail "ignore file path is unsafe"
[[ "$ignore_file" != *//* && "$ignore_file" != */ ]] || fail "ignore file path is unsafe"
# Check every component before Git or the template API reads anything. An ignore file can be
# committed as a symlink, and appending through it could change Git configuration or hooks.
IFS=/ read -r -a components <<<"$ignore_file"
component_path=""
for component in "${components[@]}"; do
  case "$component" in
    . | .[gG][iI][tT]) fail "ignore file path is unsafe" ;;
  esac
  component_path="${component_path:+$component_path/}$component"
  [[ ! -L "$component_path" ]] || fail "ignore file path contains a symlink"
done
command -v gh >/dev/null || fail "gh is unavailable"

head_sha="$(git rev-parse HEAD)" || fail "could not read the target checkout head"
[[ "$head_sha" == "$base_sha" ]] || fail "target checkout is at $head_sha, not the workflow base $base_sha"
git diff --quiet HEAD -- || fail "target checkout has uncommitted changes"

tree_entry="$(git ls-tree "$base_sha" -- "$ignore_file")" || fail "could not read the committed ignore file"
if [[ -z "$tree_entry" && ! -e "$ignore_file" ]]; then
  # Without a list of its own, the target already applies the template's list: the action only
  # restores an ignore file the target has.
  echo "The target has no $ignore_file; the template's list applies as it is." >&2
  exit 0
fi
read -r file_mode file_type file_oid file_path <<<"$tree_entry" || fail "ignore file must be a committed regular file"
[[ "$file_mode" =~ ^100(644|755)$ && "$file_type" == blob && "$file_oid" =~ ^[0-9a-f]{40}$ && "$file_path" == "$ignore_file" && -f "$ignore_file" ]] ||
  fail "ignore file must be a committed regular file"

work="$(mktemp -d)" || fail "could not create a work directory"
merged_file=""
trap 'rm -rf "$work"; [[ -z "$merged_file" ]] || rm -f -- "$merged_file"' EXIT

if ! gh api -H "Accept: application/vnd.github.raw" "repos/${source_repo}/contents/${ignore_file}?ref=${ref}" \
  >"$work/template" 2>"$work/error"; then
  if grep -q "(HTTP 404)" "$work/error"; then
    echo "::warning::${source_repo} has no ${ignore_file} on ${ref}; nothing to merge." >&2
    exit 0
  fi
  cat "$work/error" >&2
  fail "could not read ${ignore_file} from ${source_repo}@${ref}"
fi

# entries <file>: every entry line with a trailing CR removed, skipping blank lines and comments.
entries() {
  awk '{ sub(/\r$/, "") } /^[[:space:]]*$/ || /^[[:space:]]*#/ { next } { print }' "$1"
}
entries "$ignore_file" >"$work/target-entries" || fail "could not read $ignore_file"
entries "$work/template" >"$work/template-entries" || fail "could not parse the template's $ignore_file"

# Template entries the target neither lists nor opts out of with `!<entry>`, in template order.
# FILENAME, not NR==FNR, tells the files apart: an empty first file would make NR==FNR true
# for every line of the second.
awk '
  FILENAME == ARGV[1] {
    have[$0] = 1
    if (substr($0, 1, 1) == "!") have[substr($0, 2)] = 1
    next
  }
  substr($0, 1, 1) != "!" && !($0 in have) && !seen[$0]++ { print }
' "$work/target-entries" "$work/template-entries" >"$work/missing" || fail "could not compare the lists"

if [[ ! -s "$work/missing" ]]; then
  echo "The target's $ignore_file already lists every entry from ${source_repo}." >&2
  exit 0
fi

header='# --- Merged from the template by template sync. A "!<entry>" line keeps one entry out. ---'
# Decide what precedes the entries before appending, so the file is never read while written.
: >"$work/append"
[[ -z "$(tail -c1 "$ignore_file")" ]] || printf '\n' >>"$work/append"
grep -qxF -- "$header" "$ignore_file" || printf '\n%s\n' "$header" >>"$work/append"
cat "$work/missing" >>"$work/append"
# Replace the checked file instead of appending to its inode, so a local hard link cannot
# redirect the write into another file. Keep the committed file's executable mode.
merged_file="$(mktemp "${ignore_file}.XXXXXX")" || fail "could not create the replacement ignore file"
cat "$ignore_file" "$work/append" >"$merged_file" || fail "could not assemble $ignore_file"
chmod "${file_mode#100}" "$merged_file" || fail "could not preserve the ignore file mode"
mv -- "$merged_file" "$ignore_file" || fail "could not update $ignore_file"
merged_file=""

while IFS= read -r entry; do
  echo "Merged the template's ignore entry: $entry" >&2
done <"$work/missing"

git add -- "$ignore_file" || fail "could not stage $ignore_file"
git -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "chore: merge the template's ignore entries" -- "$ignore_file" ||
  fail "could not commit the merged $ignore_file"

git rev-parse HEAD
