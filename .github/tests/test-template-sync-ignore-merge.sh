#!/usr/bin/env bash

# A template's new ignore entries must reach targets created before them
# (devantler-tech/platform-tenant-template#171).
#
# actions-template-sync squash-pulls the template, then restores the target's ignore file to its
# committed copy and drops the paths that copy lists. The template's own list never decides
# anything, so an exclusion the template adds after a target was created is never applied there:
# measured in ascoachingogvaner's template-sync run 35599349324 (2026-09-21).
#
# With `merge-template-ignore-entries: true` the workflow first commits the template's missing
# entries into the target's list, so the action restores and applies the merged list. The signing
# helper then folds that local commit and the sync commit into one signed commit.
#
# This test reproduces the measured run against git fixtures: the template-only file reaches a
# target whose list predates the exclusion, and stays out once the lists are merged. It drives the
# real merge and signing helpers with an offline `gh`, and replays the action's measured git steps.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
merger="$repo_root/.github/scripts/merge-template-sync-ignore.sh"
signer="$repo_root/.github/scripts/replace-template-sync-commit.sh"
workflow="$repo_root/.github/workflows/template-sync.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$merger" ]] || fail "ignore-merge helper is missing or not executable"
[[ -x "$signer" ]] || fail "template-sync signing helper is missing or not executable"
command -v yq >/dev/null || fail "yq is unavailable"
command -v jq >/dev/null || fail "jq is unavailable"

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

export SIGNED_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
branch="chore/template-sync_deadbee"

# --- Workflow wiring: default-off flag, merge before the action, folded into the signed commit ---

# GitHub evaluates these expressions; the shell compares them as literal contracts.
# shellcheck disable=SC2016
flag_expr='${{ inputs.merge-template-ignore-entries }}'

[[ "$(yq -r '.on.workflow_call.inputs.merge-template-ignore-entries.type' "$workflow")" == "boolean" ]] ||
  fail "merge-template-ignore-entries must be a boolean input"
[[ "$(yq -r '.on.workflow_call.inputs.merge-template-ignore-entries.default' "$workflow")" == "false" ]] ||
  fail "merge-template-ignore-entries must default to false (release flag)"

step_index() {
  # step_index <yq boolean expression>: the index of the single step in the sync job it holds for.
  local found
  found="$(yq -r "[.jobs.template-sync.steps[] | $1] | to_entries | map(select(.value)) | map(.key) | .[]" "$workflow")"
  [[ "$(grep -c . <<<"$found")" == "1" ]] || fail "expected exactly one step matching $1, found: ${found:-none}"
  printf '%s\n' "$found"
}

merge_at="$(step_index '(.id == "merge-ignore")')"
sync_at="$(step_index '((.uses // "") | contains("AndreasAugustin/actions-template-sync@"))')"
helper_at="$(step_index '(.name == "📑 Checkout shared ignore-merge helper")')"
cleanup_at="$(step_index '(.name == "🧹 Remove shared ignore-merge helper")')"
((helper_at < merge_at && merge_at < cleanup_at && cleanup_at < sync_at)) ||
  fail "the ignore merge must check out its helper, run, and remove the helper before the sync action"

[[ "$(yq -r '.jobs.template-sync.steps[] | select(.id == "merge-ignore") | .if' "$workflow")" == "$flag_expr" ]] ||
  fail "the ignore merge must run only when merge-template-ignore-entries is enabled"
[[ "$(yq -r ".jobs.template-sync.steps[$helper_at].if" "$workflow")" == "$flag_expr" ]] ||
  fail "the ignore-merge helper checkout must run only when the flag is enabled"
# shellcheck disable=SC2016
[[ "$(yq -r ".jobs.template-sync.steps[$cleanup_at].if" "$workflow")" == '${{ always() && inputs.merge-template-ignore-entries }}' ]] ||
  fail "the ignore-merge helper must be removed even when the merge fails"
grep -qF 'rm -rf -- .devantler-tech-actions' <<<"$(yq -r ".jobs.template-sync.steps[$cleanup_at].run" "$workflow")" ||
  fail "the ignore-merge helper cleanup must remove the checked-out helper before the action commits"

# shellcheck disable=SC2016
[[ "$(yq -r '.jobs.template-sync.steps[] | select(.name == "✍️ Replace sync commit with a verified App commit") | .env.PRE_SYNC_SHA' "$workflow")" == '${{ steps.merge-ignore.outputs.commit }}' ]] ||
  fail "the signing step must receive the merge commit so it can fold it into the signed commit"

# --- Fixtures ---

# The fake `gh` serves the template's ignore file and the branch-publication API the signer uses.
write_fake_gh() {
  cat >"$1/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "api" ]] || exit 91
shift
method=GET
endpoint=""
accept=""
while (($#)); do
  case "$1" in
    -X|--method) method="$2"; shift 2 ;;
    --input) [[ "$2" == "-" ]] || exit 92; shift 2 ;;
    -H|--header) accept="$2"; shift 2 ;;
    --*) exit 90 ;;
    *) [[ -z "$endpoint" ]] || exit 93; endpoint="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$endpoint" >>"$FAKE_GH_LOG"

case "$method $endpoint" in
  "GET repos/example/template/contents/.templatesyncignore?ref=main" | "GET repos/example/template/contents/lists/.templatesyncignore?ref=main")
    [[ "$accept" == "Accept: application/vnd.github.raw" ]] || exit 94
    case "$FAKE_TEMPLATE_MODE" in
      file) cat "$FAKE_TEMPLATE_IGNORE" ;;
      missing)
        echo '{"message":"Not Found","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      *)
        echo "gh: Server Error (HTTP 502)" >&2
        exit 1
        ;;
    esac
    ;;
  "GET repos/example/consumer/git/ref/heads/chore/template-sync_deadbee")
    if [[ -f "$FAKE_GH_UPDATED" ]]; then
      jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
    else
      jq -n --arg sha "$REMOTE_SHA" '{object:{sha:$sha}}'
    fi
    ;;
  "POST repos/example/consumer/git/commits")
    payload="$(cat)"
    jq -e --arg tree "$EXPECTED_TREE" --arg parent "$EXPECTED_PARENT" --arg message "$EXPECTED_MESSAGE" \
      '.tree == $tree and .parents == [$parent] and .message == $message' <<<"$payload" >/dev/null || exit 95
    jq -n --arg sha "$SIGNED_SHA" '{sha:$sha,verification:{verified:true,reason:"valid"}}'
    ;;
  "PATCH repos/example/consumer/git/refs/heads/chore/template-sync_deadbee")
    payload="$(cat)"
    jq -e --arg sha "$SIGNED_SHA" '.sha == $sha and .force == true' <<<"$payload" >/dev/null || exit 96
    : >"$FAKE_GH_UPDATED"
    jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
    ;;
  "GET repos/example/consumer/commits/$SIGNED_SHA")
    jq -n --arg sha "$SIGNED_SHA" --arg tree "$EXPECTED_TREE" --arg parent "$EXPECTED_PARENT" \
      --arg message "$EXPECTED_MESSAGE" \
      '{sha:$sha,commit:{message:$message,tree:{sha:$tree},verification:{verified:true,reason:"valid"}},parents:[{sha:$parent}]}'
    ;;
  *) exit 97 ;;
esac
FAKE_GH
  chmod +x "$1/gh"
}

init_repo() {
  git init -q -b main "$1"
  git -C "$1" config user.name "Test User"
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config commit.gpgsign false
}

# The template ships a test it marks template-only, added to its list AFTER the target was created.
template_ignore='# Files a target owns.
AGENTS.md
.github/CODEOWNERS

# Template-only scaffolding.
scripts/template-only.test.sh

# This ignore-list itself.
.templatesyncignore
'

# The target's list predates `scripts/template-only.test.sh`, and owns `deploy/` on its own.
target_ignore='# Files this target owns.
AGENTS.md
.github/CODEOWNERS
deploy/

# This ignore-list itself.
.templatesyncignore
'

make_fixture() {
  local fixture="$test_root/$1"
  mkdir -p "$fixture/bin"
  write_fake_gh "$fixture/bin"

  init_repo "$fixture/template"
  mkdir -p "$fixture/template/scripts" "$fixture/template/.github"
  printf 'template agents\n' >"$fixture/template/AGENTS.md"
  printf '* @template\n' >"$fixture/template/.github/CODEOWNERS"
  printf 'shared v2\n' >"$fixture/template/scripts/shared.sh"
  printf 'template-only test\n' >"$fixture/template/scripts/template-only.test.sh"
  printf '%s' "$template_ignore" >"$fixture/template/.templatesyncignore"
  printf '%s' "$template_ignore" >"$fixture/template-ignore"
  git -C "$fixture/template" add -A
  git -C "$fixture/template" commit -q -m "template"

  init_repo "$fixture/target"
  mkdir -p "$fixture/target/scripts" "$fixture/target/.github" "$fixture/target/deploy"
  printf 'target agents\n' >"$fixture/target/AGENTS.md"
  printf '* @target\n' >"$fixture/target/.github/CODEOWNERS"
  printf 'shared v1\n' >"$fixture/target/scripts/shared.sh"
  printf 'app\n' >"$fixture/target/deploy/app.yaml"
  printf '%s' "$target_ignore" >"$fixture/target/.templatesyncignore"
  git -C "$fixture/target" add -A
  git -C "$fixture/target" commit -q -m "target"

  printf '%s\n' "$fixture"
}

# Replay the action's measured steps (run 35599349324): branch from HEAD, squash-pull the
# template, restore the ignore file to the committed copy, drop the paths that copy lists,
# then commit whatever remains. The replay applies the list's entries as literal paths, which is
# what the measured run did for plain path entries, the only kind the merge adds.
replay_template_sync() {
  local fixture="$1" repo="$1/target"
  git -C "$repo" switch -q -c "$branch"
  git -C "$repo" fetch -q "$fixture/template" main
  git -C "$repo" merge -q --squash --allow-unrelated-histories -X theirs FETCH_HEAD >/dev/null 2>&1
  # restore the ignore file
  git -C "$repo" reset -q -- .templatesyncignore
  git -C "$repo" checkout -- .templatesyncignore
  # handle .templatesyncignore
  grep -v -E '^[[:space:]]*(#|$)' "$repo/.templatesyncignore" >"$fixture/pathspecs"
  git -C "$repo" reset -q --pathspec-from-file="$fixture/pathspecs"
  git -C "$repo" clean -q --force
  git -C "$repo" checkout -- .
  git -C "$repo" add .
  if git -C "$repo" diff --cached --quiet; then
    return 0
  fi
  git -C "$repo" commit -q -m "chore: sync changes from the upstream template"
}

run_merger() {
  # run_merger <fixture> [extra args...]: the merge helper's stdout, exactly as the step reads it.
  local fixture="$1"
  shift
  (
    cd "$fixture/target"
    PATH="$fixture/bin:$PATH" FAKE_GH_LOG="$fixture/gh.log" FAKE_TEMPLATE_IGNORE="$fixture/template-ignore" \
      FAKE_TEMPLATE_MODE="${FAKE_TEMPLATE_MODE:-file}" \
      "$merger" --base-sha "$(git rev-parse HEAD)" --source-repo example/template --ref main \
      --ignore-file .templatesyncignore "$@"
  )
}

run_signer() {
  # run_signer <fixture> <base sha> [extra args...]
  local fixture="$1" base="$2"
  shift 2
  (
    cd "$fixture/target"
    PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=example/consumer FAKE_GH_LOG="$fixture/gh.log" \
      FAKE_GH_UPDATED="$fixture/updated" FAKE_TEMPLATE_IGNORE="$fixture/template-ignore" FAKE_TEMPLATE_MODE=file \
      "$signer" --base-sha "$base" --branch-prefix chore/template-sync "$@"
  )
}

in_tree() {
  git -C "$1/target" cat-file -e "$2:$3" 2>/dev/null
}

# --- RED control: without the merge, the measured run delivers the template-only file ---

fixture="$(make_fixture flag-off)"
replay_template_sync "$fixture"
in_tree "$fixture" HEAD scripts/template-only.test.sh ||
  fail "control: the replayed sync no longer reproduces platform-tenant-template#171"
[[ "$(git -C "$fixture/target" show HEAD:AGENTS.md)" == "target agents" ]] ||
  fail "control: the replayed sync overwrote a file the target's list owns"

# --- Flag on: the merged list keeps the template-only file out and is signed as one commit ---

fixture="$(make_fixture flag-on)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
merge_sha="$(run_merger "$fixture")"
[[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]] || fail "merge helper did not print the merge commit (got '$merge_sha')"
[[ "$merge_sha" == "$(git -C "$fixture/target" rev-parse HEAD)" ]] || fail "merge helper printed a commit other than HEAD"
[[ "$(git -C "$fixture/target" rev-parse "$merge_sha^")" == "$base_sha" ]] || fail "merge commit is not a child of the base"
[[ "$(git -C "$fixture/target" diff --name-only "$base_sha" "$merge_sha")" == ".templatesyncignore" ]] ||
  fail "merge commit changed more than the ignore file"

merged="$(git -C "$fixture/target" show HEAD:.templatesyncignore)"
[[ "$merged" == "${target_ignore}"* ]] || fail "merge rewrote the target's own lines instead of appending"
grep -qxF 'deploy/' <<<"$merged" || fail "merge dropped the target-only entry"
grep -qxF 'scripts/template-only.test.sh' <<<"$merged" || fail "merge did not add the template's new entry"
[[ "$(grep -cxF 'AGENTS.md' <<<"$merged")" == "1" ]] || fail "merge duplicated an entry both lists carry"

replay_template_sync "$fixture"
sync_sha="$(git -C "$fixture/target" rev-parse HEAD)"
[[ "$sync_sha" != "$merge_sha" ]] || fail "fixture: the replayed sync produced no commit"
in_tree "$fixture" HEAD scripts/template-only.test.sh &&
  fail "the template-only file still reached a target created before its exclusion"
[[ "$(git -C "$fixture/target" show HEAD:scripts/shared.sh)" == "shared v2" ]] ||
  fail "the merged list stopped a template-owned file from syncing"
[[ "$(git -C "$fixture/target" show HEAD:AGENTS.md)" == "target agents" ]] ||
  fail "the merged list lost a target-owned file"
[[ "$(git -C "$fixture/target" show HEAD:.templatesyncignore)" == "$merged" ]] ||
  fail "the sync did not keep the merged ignore list"

EXPECTED_TREE="$(git -C "$fixture/target" rev-parse 'HEAD^{tree}')"
EXPECTED_PARENT="$base_sha"
EXPECTED_MESSAGE="$(git -C "$fixture/target" log -1 --format=%B | sed '${/^$/d;}')"
REMOTE_SHA="$sync_sha"
export EXPECTED_TREE EXPECTED_PARENT EXPECTED_MESSAGE REMOTE_SHA
signed="$(run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" --pre-sync-path .templatesyncignore)"
[[ "$signed" == "$SIGNED_SHA" ]] || fail "signer did not sign the merged sync (got '$signed')"
[[ -f "$fixture/updated" ]] || fail "signer did not move the generated branch"

# Without the merge commit named, the signer still refuses the two-commit chain.
rm -f "$fixture/updated"
if run_signer "$fixture" "$base_sha" >/dev/null 2>"$fixture/error"; then
  fail "signer accepted an unnamed extra commit between the base and the sync commit"
fi
grep -q "parent does not match the workflow base sha" "$fixture/error" ||
  fail "signer refused the unnamed chain for the wrong reason: $(cat "$fixture/error")"

# A second run with the merged list in place changes nothing.
fixture2="$(make_fixture idempotent)"
run_merger "$fixture2" >/dev/null
second="$(run_merger "$fixture2")"
[[ -z "$second" ]] || fail "merge helper committed again when nothing was missing"
[[ "$(grep -c 'Merged from the template' <<<"$(git -C "$fixture2/target" show HEAD:.templatesyncignore)")" == "1" ]] ||
  fail "merge helper repeated its header"

# --- A target can keep one template entry out with a `!<entry>` line ---

fixture="$(make_fixture opt-out)"
printf '!scripts/template-only.test.sh\n' >>"$fixture/target/.templatesyncignore"
git -C "$fixture/target" commit -q -am "opt out"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
out="$(run_merger "$fixture")"
[[ -z "$out" ]] || fail "merge helper added an entry the target opted out of"
[[ "$(git -C "$fixture/target" rev-parse HEAD)" == "$base_sha" ]] || fail "opt-out run moved HEAD"
replay_template_sync "$fixture"
in_tree "$fixture" HEAD scripts/template-only.test.sh ||
  fail "the opt-out line did not let the target receive the template's file"

# --- Lists without a trailing newline, or with CRLF endings, merge cleanly ---

fixture="$(make_fixture crlf)"
printf 'AGENTS.md\r\n.github/CODEOWNERS\r\n.templatesyncignore' >"$fixture/target/.templatesyncignore"
git -C "$fixture/target" commit -q -am "crlf list"
run_merger "$fixture" >/dev/null
merged="$(git -C "$fixture/target" show HEAD:.templatesyncignore)"
grep -qx '\.templatesyncignore' <<<"$merged" || fail "merge glued an entry onto the unterminated last line"
grep -qxF 'scripts/template-only.test.sh' <<<"$merged" || fail "merge missed an entry next to CRLF lines"
[[ "$(grep -c 'AGENTS.md' <<<"$merged")" == "1" ]] || fail "merge treated a CRLF entry as missing"

# A list of comments only has no entries, so every template entry is missing from it.
fixture="$(make_fixture comments-only)"
printf '# Nothing owned yet.\n' >"$fixture/target/.templatesyncignore"
git -C "$fixture/target" commit -q -am "comments only"
run_merger "$fixture" >/dev/null 2>&1
merged="$(git -C "$fixture/target" show HEAD:.templatesyncignore)"
for entry in AGENTS.md .github/CODEOWNERS scripts/template-only.test.sh .templatesyncignore; do
  grep -qxF "$entry" <<<"$merged" || fail "merge missed '$entry' for a list without entries"
done

# --- Nothing to merge: no template list, or no target list ---

fixture="$(make_fixture template-missing)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
out="$(FAKE_TEMPLATE_MODE=missing run_merger "$fixture" 2>"$fixture/error")"
[[ -z "$out" && "$(git -C "$fixture/target" rev-parse HEAD)" == "$base_sha" ]] ||
  fail "merge helper changed the target when the template has no ignore file"
grep -q "has no .templatesyncignore" "$fixture/error" || fail "missing template list was skipped silently"

fixture="$(make_fixture target-missing)"
git -C "$fixture/target" rm -q .templatesyncignore
git -C "$fixture/target" commit -q -m "no list"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
out="$(run_merger "$fixture" 2>/dev/null)"
[[ -z "$out" && "$(git -C "$fixture/target" rev-parse HEAD)" == "$base_sha" ]] ||
  fail "merge helper created a list for a target that syncs the template's own"
[[ ! -e "$fixture/gh.log" ]] || fail "merge helper read the template's list when the target has none"

# --- Only a committed regular file can receive template entries ---

fixture="$(make_fixture symlink-ignore)"
rm "$fixture/target/.templatesyncignore"
ln -s .git/config "$fixture/target/.templatesyncignore"
git -C "$fixture/target" add .templatesyncignore
git -C "$fixture/target" commit -q -m "symlink list"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
cp "$fixture/target/.git/config" "$fixture/config-before"
printf '[CoRe]\nfsmonitor = /not-a-real-hook\n' >"$fixture/template-ignore"
if run_merger "$fixture" >/dev/null 2>"$fixture/error"; then
  fail "merge helper followed an ignore-file symlink"
fi
cmp -s "$fixture/config-before" "$fixture/target/.git/config" ||
  fail "merge helper changed Git configuration through an ignore-file symlink"
[[ ! -e "$fixture/gh.log" ]] || fail "unsafe ignore-file symlink reached the template API"
[[ "$(git -C "$fixture/target" rev-parse HEAD)" == "$base_sha" ]] || fail "unsafe ignore-file symlink moved HEAD"

fixture="$(make_fixture hardlinked-ignore)"
ln "$fixture/target/.templatesyncignore" "$fixture/other-file"
cp "$fixture/other-file" "$fixture/other-before"
run_merger "$fixture" >/dev/null
cmp -s "$fixture/other-before" "$fixture/other-file" || fail "merge helper changed another file through a hard link"
grep -qxF scripts/template-only.test.sh "$fixture/target/.templatesyncignore" ||
  fail "merge helper omitted a template entry from a hardlinked regular file"

fixture="$(make_fixture empty-ignore)"
: >"$fixture/target/.templatesyncignore"
git -C "$fixture/target" commit -q -am "empty list"
merge_sha="$(run_merger "$fixture")"
[[ -n "$merge_sha" ]] || fail "merge helper treated a tracked empty list as absent"
grep -qxF scripts/template-only.test.sh "$fixture/target/.templatesyncignore" ||
  fail "merge helper omitted a template entry from an empty target list"

fixture="$(make_fixture executable-ignore)"
chmod +x "$fixture/target/.templatesyncignore"
git -C "$fixture/target" commit -q -am "executable list"
run_merger "$fixture" >/dev/null
[[ "$(git -C "$fixture/target" ls-tree HEAD -- .templatesyncignore)" == 100755* ]] ||
  fail "merge helper changed an executable ignore file's mode"

fixture="$(make_fixture nested-ignore)"
mkdir "$fixture/target/lists"
git -C "$fixture/target" mv .templatesyncignore lists/.templatesyncignore
git -C "$fixture/target" commit -q -m "nested list"
run_merger "$fixture" --ignore-file lists/.templatesyncignore >/dev/null
grep -qxF scripts/template-only.test.sh "$fixture/target/lists/.templatesyncignore" ||
  fail "merge helper omitted a template entry from a nested regular file"

fixture="$(make_fixture untracked-ignore)"
git -C "$fixture/target" rm -q .templatesyncignore
git -C "$fixture/target" commit -q -m "no committed list"
printf 'target-only\n' >"$fixture/target/.templatesyncignore"
if run_merger "$fixture" >/dev/null 2>"$fixture/error"; then
  fail "merge helper changed an untracked ignore file"
fi
[[ ! -e "$fixture/gh.log" ]] || fail "untracked ignore file reached the template API"

fixture="$(make_fixture symlink-parent)"
ln -s .git "$fixture/target/ignore-dir"
git -C "$fixture/target" add ignore-dir
git -C "$fixture/target" commit -q -m "symlink parent"
cp "$fixture/target/.git/config" "$fixture/config-before"
if run_merger "$fixture" --ignore-file ignore-dir/config >/dev/null 2>"$fixture/error"; then
  fail "merge helper followed an ignore-file parent symlink"
fi
cmp -s "$fixture/config-before" "$fixture/target/.git/config" ||
  fail "merge helper changed Git configuration through a parent symlink"
[[ ! -e "$fixture/gh.log" ]] || fail "unsafe parent symlink reached the template API"

fixture="$(make_fixture git-internal)"
cp "$fixture/target/.git/config" "$fixture/config-before"
if run_merger "$fixture" --ignore-file .git/config >/dev/null 2>"$fixture/error"; then
  fail "merge helper accepted a Git-internal destination"
fi
cmp -s "$fixture/config-before" "$fixture/target/.git/config" || fail "merge helper changed a Git-internal destination"
[[ ! -e "$fixture/gh.log" ]] || fail "Git-internal destination reached the template API"

# --- Fail closed ---

fixture="$(make_fixture template-error)"
if FAKE_TEMPLATE_MODE=error run_merger "$fixture" >/dev/null 2>"$fixture/error"; then
  fail "merge helper treated an unreadable template list as empty"
fi
grep -q "could not read" "$fixture/error" || fail "unreadable template list failed for the wrong reason"

fixture="$(make_fixture moved-head)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
printf 'later\n' >"$fixture/target/later.txt"
git -C "$fixture/target" add later.txt
git -C "$fixture/target" commit -q -m "later"
if (
  cd "$fixture/target"
  PATH="$fixture/bin:$PATH" FAKE_GH_LOG="$fixture/gh.log" FAKE_TEMPLATE_IGNORE="$fixture/template-ignore" \
    FAKE_TEMPLATE_MODE=file "$merger" --base-sha "$base_sha" --source-repo example/template --ref main \
    --ignore-file .templatesyncignore
) >/dev/null 2>"$fixture/error"; then
  fail "merge helper committed on top of a checkout that is not the workflow base"
fi

fixture="$(make_fixture dirty)"
printf 'edited\n' >>"$fixture/target/AGENTS.md"
if run_merger "$fixture" >/dev/null 2>"$fixture/error"; then
  fail "merge helper committed over uncommitted changes"
fi

bad_index=0
for bad in "../escape" "/abs" "a b" "./.templatesyncignore" "a/./b" "a//b" "a/" ".GIT/config" "a/.gIt/config"; do
  bad_index=$((bad_index + 1))
  fixture="$(make_fixture "bad-path-$bad_index")"
  if (
    cd "$fixture/target"
    PATH="$fixture/bin:$PATH" FAKE_GH_LOG="$fixture/gh.log" FAKE_TEMPLATE_IGNORE="$fixture/template-ignore" \
      FAKE_TEMPLATE_MODE=file "$merger" --base-sha "$(git rev-parse HEAD)" --source-repo example/template \
      --ref main --ignore-file "$bad"
  ) >/dev/null 2>&1; then
    fail "merge helper accepted the unsafe ignore-file path '$bad'"
  fi
  [[ ! -e "$fixture/gh.log" ]] || fail "unsafe ignore-file path reached the template API"
done

# --- Signer: the merge commit is folded in only when it is exactly what the merge produced ---

fixture="$(make_fixture sign-no-sync)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
git -C "$fixture/target" switch -q -c "$branch"
merge_sha="$(run_merger "$fixture")"
out="$(run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" --pre-sync-path .templatesyncignore)"
grep -q "No template-sync commit" <<<"$out" || fail "signer did not skip a run whose only commit is the merge"
! grep -q -v '/contents/' "$fixture/gh.log" || fail "signer called the GitHub API when there was nothing to sign"

fixture="$(make_fixture sign-extra-path)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
printf 'scripts/template-only.test.sh\n' >>"$fixture/target/.templatesyncignore"
printf 'smuggled\n' >"$fixture/target/extra.txt"
git -C "$fixture/target" add .templatesyncignore extra.txt
git -C "$fixture/target" commit -q -m "merge plus extra"
merge_sha="$(git -C "$fixture/target" rev-parse HEAD)"
replay_template_sync "$fixture"
if run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" --pre-sync-path .templatesyncignore \
  >/dev/null 2>"$fixture/error"; then
  fail "signer folded in a merge commit that changed more than the ignore file"
fi
grep -q "changed more than" "$fixture/error" || fail "extra-path merge commit failed for the wrong reason"

fixture="$(make_fixture sign-wrong-parent)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
merge_sha="$(run_merger "$fixture")"
printf 'between\n' >"$fixture/target/between.txt"
git -C "$fixture/target" add between.txt
git -C "$fixture/target" commit -q -m "between"
replay_template_sync "$fixture"
if run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" --pre-sync-path .templatesyncignore \
  >/dev/null 2>"$fixture/error"; then
  fail "signer accepted a sync commit whose parent is not the merge commit"
fi
grep -q "parent does not match the pre-sync commit" "$fixture/error" ||
  fail "a commit between the merge and the sync failed for the wrong reason: $(cat "$fixture/error")"

if run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" >/dev/null 2>"$fixture/error"; then
  fail "signer accepted --pre-sync-sha without --pre-sync-path"
fi
grep -q "needs --pre-sync-path" "$fixture/error" || fail "a lone --pre-sync-sha failed for the wrong reason"

fixture="$(make_fixture sign-merge-not-on-base)"
base_sha="$(git -C "$fixture/target" rev-parse HEAD)"
printf 'before\n' >"$fixture/target/before.txt"
git -C "$fixture/target" add before.txt
git -C "$fixture/target" commit -q -m "before the merge"
merge_sha="$(run_merger "$fixture" 2>/dev/null)"
replay_template_sync "$fixture"
if run_signer "$fixture" "$base_sha" --pre-sync-sha "$merge_sha" --pre-sync-path .templatesyncignore \
  >/dev/null 2>"$fixture/error"; then
  fail "signer folded in a merge commit that does not sit on the workflow base"
fi
grep -q "pre-sync commit parent does not match the workflow base sha" "$fixture/error" ||
  fail "an off-base merge commit failed for the wrong reason: $(cat "$fixture/error")"

echo "PASS: template sync merges the template's new ignore entries into the target's list and signs one commit"
