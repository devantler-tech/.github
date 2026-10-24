#!/usr/bin/env bash
# Contract test for update-agent-skills `pins` (#715): a listed skill is reinstalled at its reviewed
# upstream commit before `gh skill update --all` runs, the whole skill directory is replaced, a second
# run with the same pins changes nothing, and any invalid line fails the run before a skill changes.
# With no pins the action makes no install call and behaves exactly as before.
#
# Runs the action's update step EXTRACTED FROM action.yaml, never a transcription, with a stub `gh`
# that records every call and writes what `gh skill install --pin` writes. The real CLI's pin
# behaviour is exercised by the `test-update-agent-skills-mark-internal` CI job.
# shellcheck disable=SC2016 # the wiring assertions compare literal ${{ }} strings on purpose
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
action_dir="$repo_root/actions/update-agent-skills"
step_name="🔄 Update skills"
commit=0123456789abcdef0123456789abcdef01234567
other=89abcdef0123456789abcdef0123456789abcdef

fail() {
  echo "::error::$*"
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq is required to run this test"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$work/update-step.sh"
STEP="$step_name" yq -r '.runs.steps[] | select(.name == strenv(STEP)) | .run' \
  "$action_dir/action.yaml" >"$script"
[[ -s "$script" ]] || fail "action.yaml has no '$step_name' step to exercise"

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "skill update") echo "All skills are up to date."; exit 0 ;;
  "skill install") ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
[[ "${STUB_INSTALL:-ok}" != fail ]] || { echo "install failed" >&2; exit 1; }
[[ "$4" != "${STUB_FAIL_PATH:-}" ]] || { echo "install of $4 failed" >&2; exit 1; }
repo=$3 md_path=$4
[[ "$5 $7" == "--pin --dir" && $# -eq 8 ]] || { echo "unexpected install flags: $*" >&2; exit 64; }
pin=$6 dest=$8
# Like the real CLI, refuse a destination that already holds the skill.
[[ -z "$(ls -A "$dest" 2>/dev/null)" ]] || { echo "$dest is not empty" >&2; exit 1; }
if [[ "${STUB_INSTALL:-ok}" == flaky && ! -e "$GH_LOG.flaked" ]]; then
  : >"$GH_LOG.flaked"
  mkdir -p "$dest/partial" && printf "partial\n" >"$dest/partial/left-over.md"
  echo "transient failure" >&2
  exit 1
fi
path=${md_path%/SKILL.md}
name=${path##*/}
mkdir -p "$dest/$name/references"
pinned_line="    github-pinned: $pin"
[[ "${STUB_INSTALL:-ok}" != no-pin ]] || pinned_line=""
cat >"$dest/$name/SKILL.md" <<SKILL
---
name: $name
description: Upstream $name at $pin.
metadata:
    github-path: $path
$pinned_line
    github-ref: $pin
    github-repo: https://github.com/$repo
    github-tree-sha: 1111111111111111111111111111111111111111
---
# $name at $pin
SKILL
printf 'reference at %s\n' "$pin" >"$dest/$name/references/guide.md"
echo "Installed $name from $repo@$pin"
EOF
chmod +x "$work/bin/gh"

skills="$work/repo/.agents/skills"
new_skills() {
  rm -rf "$work/repo"
  mkdir -p "$skills/git-commit" "$skills/other" "$work/repo/outside/stray"
  cat >"$skills/git-commit/SKILL.md" <<'SKILL'
---
name: git-commit
description: Current upstream version.
metadata:
    github-path: skills/git-commit
    github-ref: refs/heads/main
    github-repo: https://github.com/example/skills
    github-tree-sha: 2222222222222222222222222222222222222222
---
# git-commit (newer, unreviewed)
SKILL
  printf 'stale file an older install left behind\n' >"$skills/git-commit/stale.md"
  printf -- '---\nname: other\ndescription: Other.\n---\n# Other\n' >"$skills/other/SKILL.md"
  mkdir -p "$skills/lint"
  printf -- "---\nname: lint\nmetadata:\n    github-repo: https://github.com/example/skills\n    github-path: skills/lint\n---\n# Lint\n" >"$skills/lint/SKILL.md"
  printf -- '---\nname: stray\nmetadata:\n    github-repo: https://github.com/example/skills\n    github-path: skills/stray\n---\n' \
    >"$work/repo/outside/stray/SKILL.md"
}

tree_hash() { (cd "$work/repo" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }

# run <pins> [unpin] [dry-run] [mark-internal] — runs the step from the fake repository root.
run() {
  : >"$work/github-output"
  : >"$GH_LOG"
  (
    cd "$work/repo"
    PATH="$work/bin:$PATH" GITHUB_ACTION_PATH="$action_dir" GITHUB_OUTPUT="$work/github-output" \
      GH_TOKEN=stub-not-a-secret RETRY_MAX_ATTEMPTS="${RETRY_RUN_MAX:-1}" RETRY_BASE_DELAY=0 \
      INPUT_DIR=.agents/skills INPUT_PINS="$1" INPUT_UNPIN="${2:-false}" INPUT_DRY_RUN="${3:-false}" INPUT_MARK_INTERNAL="${4:-false}" \
      bash --noprofile --norc -eo pipefail "$script"
  ) >"$work/step.log" 2>&1
}
changed() { sed -n 's/^changed=//p' "$work/github-output"; }
installs() { grep -c '^skill install' "$GH_LOG" || true; }
meta() { yq --front-matter=extract ".metadata.\"$1\"" "$skills/git-commit/SKILL.md"; }

export GH_LOG="$work/gh.log"

# ── Off: omitted, empty or whitespace-only pins make no install call ──
for pins in "" $'\n  \n'; do
  new_skills
  run "$pins" || fail "empty pins failed: $(cat "$work/step.log")"
  [[ "$(installs)" == 0 ]] || fail "empty pins made an install call"
  [[ "$(changed)" == false ]] || fail "empty pins reported changed=$(changed)"
done
new_skills
before=$(tree_hash)
( cd "$work/repo" && unset INPUT_PINS && PATH="$work/bin:$PATH" GITHUB_ACTION_PATH="$action_dir" \
  GITHUB_OUTPUT="$work/github-output" GH_TOKEN=stub-not-a-secret RETRY_MAX_ATTEMPTS=1 \
  INPUT_DIR=.agents/skills INPUT_UNPIN=false INPUT_DRY_RUN=false INPUT_MARK_INTERNAL=false \
  bash --noprofile --norc -eo pipefail "$script" ) >"$work/step.log" 2>&1 ||
  fail "an unset pins input failed: $(cat "$work/step.log")"
[[ "$(tree_hash)" == "$before" ]] || fail "an unset pins input changed files"
echo "ok   off: no pins, no install call, no change"

# ── On: the listed skill is replaced by the pinned upstream content ──
pins=$(printf '%s\n' \
  "# Hold until example/skills#1 is fixed." \
  "" \
  "  .agents/skills/git-commit   $commit   # example/skills#1  ")
new_skills
other_before=$(shasum -a 256 "$skills/other/SKILL.md")
run "$pins" || fail "a valid pin failed: $(cat "$work/step.log")"
[[ "$(installs)" == 1 ]] || fail "expected one install call, got $(installs)"
grep -qE "^skill install example/skills skills/git-commit/SKILL.md --pin $commit --dir [^ ]+\$" "$GH_LOG" ||
  fail "install did not use the skill's own repository, path and commit: $(cat "$GH_LOG")"
[[ "$(meta github-pinned)" == "$commit" ]] || fail "github-pinned is $(meta github-pinned), expected $commit"
[[ "$(meta github-repo)" == "https://github.com/example/skills" ]] || fail "github-repo changed"
[[ ! -e "$skills/git-commit/stale.md" ]] || fail "a file the pinned commit does not have was kept"
[[ -f "$skills/git-commit/references/guide.md" ]] || fail "the pinned commit's auxiliary file is missing"
[[ "$(shasum -a 256 "$skills/other/SKILL.md")" == "$other_before" ]] || fail "an unlisted skill changed"
[[ "$(changed)" == true ]] || fail "a pin that replaced content reported changed=$(changed)"
grep -qF "Pinned: .agents/skills/git-commit to example/skills@$commit" "$work/github-output" ||
  fail "updated-skills does not report the pin"
pinned_tree=$(tree_hash)
echo "ok   on: skill replaced at the pinned commit, changed=true"

# Idempotent: the same pins again leave every file as it was.
run "$pins" || fail "a repeated pin failed: $(cat "$work/step.log")"
[[ "$(installs)" == 0 ]] || fail "a skill already pinned to the commit was reinstalled"
[[ "$(tree_hash)" == "$pinned_tree" ]] || fail "a repeated pin changed files"
[[ "$(changed)" == false ]] || fail "a repeated pin reported changed=$(changed)"
echo "ok   repeated pins: no change"

# mark-internal still applies to a pinned skill.
new_skills
run "$pins" false false true || fail "pin + mark-internal failed: $(cat "$work/step.log")"
[[ "$(meta internal)" == true ]] || fail "mark-internal did not apply to the pinned skill"
[[ "$(meta github-pinned)" == "$commit" ]] || fail "mark-internal lost the pin"
echo "ok   mark-internal applies to a pinned skill"

# ── Refusals: nothing changes and nothing is installed ──
refuse() { # <label> <pins> <expected message> [unpin] [stub]
  new_skills
  local before
  before=$(tree_hash)
  if STUB_INSTALL="${5:-ok}" run "$2" "${4:-false}"; then
    fail "$1: the step succeeded"
  fi
  grep -qF -- "$3" "$work/step.log" || fail "$1: expected '$3' in: $(cat "$work/step.log")"
  [[ "$(tree_hash)" == "$before" ]] || fail "$1: files changed"
  echo "ok   refused: $1"
}
refuse "short commit" ".agents/skills/git-commit 0123456" "not a full 40-character lowercase commit SHA"
refuse "uppercase commit" ".agents/skills/git-commit $(tr a-f A-F <<< "$commit")" "not a full 40-character lowercase commit SHA"
refuse "missing commit" ".agents/skills/git-commit" "expected '<skill-dir> <40-character commit>'"
refuse "extra field" ".agents/skills/git-commit $commit extra" "expected '<skill-dir> <40-character commit>'"
refuse "not installed" ".agents/skills/absent $commit" "is not an installed skill directory"
refuse "outside dir" "outside/stray $commit" "is not a skill directory under"
refuse "duplicate" $'.agents/skills/git-commit '"$commit"$'\n.agents/skills/./git-commit '"$other" "is pinned more than once"
refuse "one bad line among good" $'.agents/skills/git-commit '"$commit"$'\n.agents/skills/other 0123' "pins line 2"
refuse "no source metadata" ".agents/skills/other $commit" "has no github-repo"
refuse "unpin" ".agents/skills/git-commit $commit" "cannot be combined with 'unpin'" true
refuse "install fails" ".agents/skills/git-commit $commit" "no skill was pinned" false fail
refuse "install not pinned" ".agents/skills/git-commit $commit" "installed without github-pinned" false no-pin
STUB_FAIL_PATH=skills/lint/SKILL.md refuse "second install fails" $'.agents/skills/git-commit '"$commit"$'\n.agents/skills/lint '"$commit" "no skill was pinned"

# Validation precedes every install, so a bad later line means no install call at all.
new_skills
run $'.agents/skills/git-commit '"$commit"$'\nnot-a-dir '"$commit" && fail "a bad second line was accepted"
[[ "$(installs)" == 0 ]] || fail "a skill was installed although a later line was invalid"
echo "ok   validation precedes installation"

# The skills directory itself is not a skill, even when it holds a SKILL.md.
new_skills
cp "$skills/git-commit/SKILL.md" "$skills/SKILL.md"
run ".agents/skills $commit" && fail "the skills directory itself was accepted as a skill"
grep -qF "is not a skill directory under" "$work/step.log" || fail "dir itself: unexpected failure: $(cat "$work/step.log")"
echo "ok   refused: dir itself"

# A retried install starts from an empty staging directory, so a failed attempt leaves nothing behind.
new_skills
rm -f "$GH_LOG.flaked"
STUB_INSTALL=flaky RETRY_RUN_MAX=2 run ".agents/skills/git-commit $commit" ||
  fail "a pin did not recover from one transient install failure: $(cat "$work/step.log")"
[[ "$(installs)" == 2 ]] || fail "expected a retried install, got $(installs) install call(s)"
[[ ! -e "$skills/git-commit/left-over.md" && ! -e "$skills/partial" ]] || fail "a failed attempt's files were kept"
[[ "$(meta github-pinned)" == "$commit" ]] || fail "the retried pin was not applied"
echo "ok   retry starts from an empty staging directory"

# A list of comments pins nothing, so it neither installs nor conflicts with unpin.
new_skills
run $'# nothing pinned right now\n  # still nothing' true || fail "comment-only pins failed: $(cat "$work/step.log")"
[[ "$(installs)" == 0 ]] || fail "comment-only pins made an install call"
echo "ok   comment-only pins are empty"

# ── Dry-run validates and reports without installing ──
new_skills
before=$(tree_hash)
run ".agents/skills/git-commit $commit" false true || fail "dry-run pin failed: $(cat "$work/step.log")"
[[ "$(installs)" == 0 ]] || fail "dry-run installed a skill"
[[ "$(tree_hash)" == "$before" ]] || fail "dry-run changed files"
grep -qF "Would pin: .agents/skills/git-commit to example/skills@$commit" "$work/step.log" || fail "dry-run did not report the pin"
run ".agents/skills/git-commit 0123" false true && fail "dry-run accepted an invalid pin"
echo "ok   dry-run validates without installing"

# ── Wiring: the input reaches the step from both entrypoints, default empty ──
workflow="$repo_root/.github/workflows/update-agent-skills.yaml"
[[ "$(yq -r '.inputs.pins.default' "$action_dir/action.yaml")" == "" ]] || fail "action input pins must default to empty"
[[ "$(yq -r '.runs.steps[] | select(.id == "update") | .env.INPUT_PINS' "$action_dir/action.yaml")" == '${{ inputs.pins }}' ]] ||
  fail "action update step must receive pins as INPUT_PINS"
[[ "$(yq -r '.on.workflow_call.inputs.pins.type' "$workflow")" == string ]] || fail "reusable workflow input pins must be a string"
[[ "$(yq -r '.on.workflow_call.inputs.pins.default' "$workflow")" == "" ]] || fail "reusable workflow input pins must default to empty"
forwarded=$(yq -r '.jobs."update-agent-skills".steps[] | select(.uses == "./.devantler-tech-actions/actions/update-agent-skills") | .with.pins' "$workflow")
[[ "$forwarded" == '${{ inputs.pins }}' ]] || fail "reusable workflow must forward pins (got: $forwarded)"

echo "pins contract: all assertions passed"
