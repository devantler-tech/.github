#!/usr/bin/env bash
# Exercise native decisions, then prove their observation oracles reject regressions.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
fixture="$root/.github/tests/create-release-stable-channel-fixture.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[[ -f "$fixture" ]] || { echo 'FAIL: maintained stable-channel fixture is missing' >&2; exit 1; }
real_npx="$(command -v npx)"
mkdir -p "$work/bin" "$work/template/hooks"
printf '#!/bin/sh\nexit 99\n' > "$work/template/hooks/pre-commit"
chmod +x "$work/template/hooks/pre-commit"
if ! env GIT_DIR="$work/foreign-git" GIT_WORK_TREE="$work/foreign-tree" GIT_INDEX_FILE="$work/foreign-index" \
  GIT_TEMPLATE_DIR="$work/template" GIT_CONFIG_PARAMETERS="'core.hooksPath'='$work/template/hooks'" \
  bash "$fixture" > "$work/output" 2>&1; then
  cat "$work/output" >&2
  exit 1
fi
[[ ! -e "$work/foreign-git" && ! -e "$work/foreign-tree" && ! -e "$work/foreign-index" ]]
for kind in lightweight annotated; do
  for notes in absent matching; do
    for version in none 1.2.5; do
      grep -qxF "PASS: $kind-$notes -> $version; files and local/remote refs unchanged" "$work/output"
    done
  done
done
cat "$work/output"
printf '%s\n' "$real_npx" > "$work/real-npx"
cat > "$work/bin/npx" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
work="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
"$(cat "$work/real-npx")" "$@" > "$work/native-output" 2>&1
# Each mutation follows a real pinned dry-run, inside its disposable local repository.
case "$(cat "$work/fault")" in
  initial-decision) sed 's/no new version is released/fixture removed the no-release observation/g' "$work/native-output"; exit 0 ;;
  next-decision) sed 's/The next release version is 1.2.5/The next release version is 1.2.50/g' "$work/native-output"; exit 0 ;;
  prerelease-decision) sed 's/The next release version is 1.2.5/The next release version is 1.2.5-beta.1/g' "$work/native-output"; exit 0 ;;
  local-note) git -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false notes --ref=fixture-unexpected add -m '{}' HEAD ;;
  remote-note)
    previous=''
    for argument in "$@"; do
      if [[ "$previous" == --repository-url ]]; then remote="${argument#file://}"; fi
      previous="$argument"
    done
    git --git-dir="$remote" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false notes --ref=fixture-unexpected add -m '{}' v1.2.4
    ;;
  tag-move) git update-ref refs/tags/v1.2.4 HEAD~1 ;;
  tracked-file) printf '\nchanged\n' >> .releaserc ;;
  untracked-file) printf 'changed\n' > unexpected-file ;;
  *) exit 99 ;;
esac
cat "$work/native-output"
WRAPPER
chmod +x "$work/bin/npx"
controls=0
while IFS=$'\t' read -r fault diagnostic; do
  printf '%s\n' "$fault" > "$work/fault"
  if PATH="$work/bin:$PATH" bash "$fixture" > "$work/output" 2>&1; then
    echo "FAIL: $fault was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/output" || { cat "$work/output" >&2; exit 1; }
  controls=$((controls + 1))
  printf 'PASS: rejected %s after native release decision\n' "$fault"
done <<'CASES'
initial-decision	expected no release
next-decision	expected 1.2.5
prerelease-decision	expected 1.2.5
local-note	changed local refs
remote-note	changed remote refs
tag-move	changed local refs
tracked-file	changed consumer files
untracked-file	changed consumer files
CASES
[[ "$controls" == 8 ]]
mkdir -p "$work/mutated/.github/tests"
# Reproduce the annotated-tag setup error: the tag object has a note, but the
# commit projection used by semantic-release cannot see it.
original="$(cat "$fixture")"
needle="notes add -m '{\"channels\":[null]}' \"\$stranded\""
replacement="notes add -m '{\"channels\":[null]}' v1.2.4"
[[ "$original" == *"$needle"* ]] || { echo 'FAIL: note-target mutation did not apply' >&2; exit 1; }
printf '%s\n' "${original/"$needle"/"$replacement"}" > "$work/mutated/.github/tests/fixture.sh"
if bash "$work/mutated/.github/tests/fixture.sh" "$root/.github/workflows/create-release.yaml" "$root/.releaserc" > "$work/output" 2>&1; then
  echo 'FAIL: annotated tag-object note was accepted as a matching commit note' >&2
  exit 1
fi
grep -qF 'FAIL: annotated-matching incorrect channel-note projection' "$work/output" || { cat "$work/output" >&2; exit 1; }
echo 'PASS: native projection rejects an annotated tag-object note'
echo 'PASS: stable-channel observation controls reject incorrect decisions, tag/notes changes and consumer-file mutations'
