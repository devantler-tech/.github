#!/usr/bin/env bash

# A template sync that changes nothing must leave no pull request and no branch behind (#467).
#
# Every consumer squash-merges its sync pull request, so an already delivered template commit is
# proposed again with no changed files (wedding-app#377, ascoachingogvaner#280). This drives the
# real helper against git fixtures and an offline `gh`, and checks the workflow runs it between
# the sync action and the signing step.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/.github/scripts/discard-empty-template-sync.sh"
workflow="$repo_root/.github/workflows/template-sync.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$helper" ]] || fail "empty-sync helper is missing or not executable"
command -v yq >/dev/null || fail "yq is unavailable"

# --- workflow wiring -------------------------------------------------------------------------

step_index() {
  yq -r ".jobs.template-sync.steps | to_entries[] | select(.value | $1) | .key" "$workflow"
}

sync_at="$(step_index '((.uses // "") | contains("AndreasAugustin/actions-template-sync@"))')"
checkout_at="$(step_index '(.name == "📑 Checkout shared post-sync helpers")')"
discard_at="$(step_index '(.id == "discard-empty")')"
sign_at="$(step_index '(.name == "✍️ Replace sync commit with a verified App commit")')"
cleanup_at="$(step_index '(.name == "🧹 Remove shared post-sync helpers")')"
for index in "$sync_at" "$checkout_at" "$discard_at" "$sign_at" "$cleanup_at"; do
  [[ "$index" =~ ^[0-9]+$ ]] || fail "a post-sync step is missing or duplicated (got '$index')"
done
((sync_at < checkout_at && checkout_at < discard_at && discard_at < sign_at && sign_at < cleanup_at)) ||
  fail "the empty-sync check must run after the sync action and before the signing step"

step_field() {
  yq -r ".jobs.template-sync.steps[$1].$2 // \"\"" "$workflow"
}

[[ -z "$(step_field "$checkout_at" if)" ]] ||
  fail "the post-sync helper checkout must run on both token paths"
[[ -z "$(step_field "$discard_at" if)" ]] ||
  fail "the empty-sync check must run on both token paths"
# GitHub evaluates these expressions; the shell compares them as literal contracts.
# shellcheck disable=SC2016
[[ "$(step_field "$discard_at" env.GH_TOKEN)" == '${{ steps.app-token.outputs.token || github.token }}' ]] ||
  fail "the empty-sync check must use the same token that opened the pull request"
# shellcheck disable=SC2016
[[ "$(step_field "$sign_at" if)" == '${{ inputs.use-app-token && steps.discard-empty.outputs.result != '"'discarded'"' }}' ]] ||
  fail "the signing step must be skipped once the empty pull request is discarded"
# shellcheck disable=SC2016
[[ "$(step_field "$cleanup_at" if)" == '${{ always() }}' ]] ||
  fail "the post-sync helpers must be removed even when a step fails"
grep -q 'discard-empty-template-sync.sh' <<<"$(step_field "$discard_at" run)" ||
  fail "the empty-sync step does not call the helper"
# shellcheck disable=SC2016
grep -q 'result=\$result" >> "\$GITHUB_OUTPUT"' <<<"$(step_field "$discard_at" run)" ||
  fail "the empty-sync step does not publish its result for the signing step"

# --- helper behaviour ------------------------------------------------------------------------

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

branch="chore/template-sync_deadbee"

make_fixture() {
  local name="$1"
  local fixture="$test_root/$name"
  mkdir -p "$fixture/bin" "$fixture/repo"

  git -C "$fixture/repo" init -q -b main
  git -C "$fixture/repo" config user.name "Test User"
  git -C "$fixture/repo" config user.email "test@example.com"
  git -C "$fixture/repo" config commit.gpgsign false
  printf 'base\n' >"$fixture/repo/file.txt"
  git -C "$fixture/repo" add file.txt
  git -C "$fixture/repo" commit -q -m "base"

  cat >"$fixture/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "api" ]] || exit 91
shift

method=GET
endpoint=""
while (($#)); do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    --input)
      [[ "$2" == "-" ]] || exit 92
      shift 2
      ;;
    *)
      [[ -z "$endpoint" ]] || exit 93
      endpoint="$1"
      shift
      ;;
  esac
done

printf '%s %s\n' "$method" "$endpoint" >>"$FAKE_GH_LOG"

case "$method $endpoint" in
  "GET repos/example/consumer/git/ref/heads/chore/template-sync_deadbee")
    jq -n --arg sha "$REMOTE_SHA" '{object:{sha:$sha}}'
    ;;
  "GET repos/example/consumer/pulls?state=open&head=example:chore/template-sync_deadbee&per_page=100")
    printf '%s\n' "$FAKE_PULLS"
    ;;
  "POST repos/example/consumer/issues/41/comments")
    jq -e '.body | test("changes no files")' >/dev/null || exit 94
    echo '{}'
    ;;
  "PATCH repos/example/consumer/pulls/41")
    jq -e '. == {state:"closed"}' >/dev/null || exit 95
    [[ "$FAKE_GH_MODE" != "close-fails" ]] || exit 1
    if [[ "$FAKE_GH_MODE" == "stays-open" ]]; then
      echo '{"state":"open"}'
      exit 0
    fi
    echo '{"state":"closed"}'
    ;;
  "DELETE repos/example/consumer/git/refs/heads/chore/template-sync_deadbee")
    ;;
  *)
    exit 96
    ;;
esac
FAKE_GH
  chmod +x "$fixture/bin/gh"
  printf '%s\n' "$fixture"
}

# sync_commit <fixture> <branch> [content]: the action's commit; without content it is empty.
sync_commit() {
  git -C "$1/repo" switch -q -c "$2"
  if [[ $# -ge 3 ]]; then
    printf '%s\n' "$3" >"$1/repo/file.txt"
    git -C "$1/repo" add file.txt
  fi
  git -C "$1/repo" commit -q --allow-empty -m "chore: sync changes from the upstream template"
}

# run_helper <fixture> <base-sha>: status in $rc, stdout in output, stderr in error, calls in gh.log.
run_helper() {
  rc=0
  (
    cd "$1/repo"
    PATH="$1/bin:$PATH" GITHUB_REPOSITORY=example/consumer FAKE_GH_LOG="$1/gh.log" \
      "$helper" --base-sha "$2" --branch-prefix chore/template-sync
  ) >"$1/output" 2>"$1/error" || rc=$?
}

writes() {
  [[ -e "$1/gh.log" ]] || return 0
  grep -vE '^GET ' "$1/gh.log" || true
}

pull_list() {
  jq -cn --arg ref "$1" --arg sha "$2" '[{number:41,head:{ref:$ref,sha:$sha}}]'
}

export FAKE_GH_MODE=success

# 1. The measured case: an empty sync commit with its pull request open.
fixture="$(make_fixture empty)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS="$(pull_list "$branch" "$REMOTE_SHA")"
export REMOTE_SHA FAKE_PULLS
run_helper "$fixture" "$base"
[[ "$rc" -eq 0 ]] || fail "empty — the helper failed: $(cat "$fixture/error")"
[[ "$(cat "$fixture/output")" == "discarded" ]] || fail "empty — expected 'discarded', got '$(cat "$fixture/output")'"
expected_writes="POST repos/example/consumer/issues/41/comments
PATCH repos/example/consumer/pulls/41
DELETE repos/example/consumer/git/refs/heads/$branch"
[[ "$(writes "$fixture")" == "$expected_writes" ]] ||
  fail "empty — expected comment, close, delete in that order, got: $(writes "$fixture")"

# 2. An empty sync whose pull request is already gone still loses its branch.
fixture="$(make_fixture empty-no-pr)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS='[]'
run_helper "$fixture" "$base"
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "discarded" ]] ||
  fail "empty without a pull request — expected 'discarded': $(cat "$fixture/error")"
[[ "$(writes "$fixture")" == "DELETE repos/example/consumer/git/refs/heads/$branch" ]] ||
  fail "empty without a pull request — expected only the branch deletion, got: $(writes "$fixture")"

# 3. A real sync is left alone and costs no API call.
fixture="$(make_fixture changed)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch" synced
run_helper "$fixture" "$base"
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "changed" ]] ||
  fail "changed — expected 'changed', got '$(cat "$fixture/output")': $(cat "$fixture/error")"
[[ ! -e "$fixture/gh.log" ]] || fail "changed — a real sync called the GitHub API"

# 4. No sync commit at all.
fixture="$(make_fixture none)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
run_helper "$fixture" "$base"
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "none" ]] ||
  fail "none — expected 'none', got '$(cat "$fixture/output")': $(cat "$fixture/error")"
[[ ! -e "$fixture/gh.log" ]] || fail "none — the no-commit path called the GitHub API"

# refused <case> <fixture> <base> <error pattern>: the helper fails, writes nothing, names the reason.
refused() {
  run_helper "$2" "$3"
  [[ "$rc" -ne 0 ]] || fail "$1 — the helper discarded anyway"
  [[ -z "$(cat "$2/output")" ]] || fail "$1 — a refusal still printed a result: $(cat "$2/output")"
  [[ -z "$(writes "$2")" ]] || fail "$1 — a refusal still wrote: $(writes "$2")"
  grep -q "$4" "$2/error" || fail "$1 — the refusal did not name its reason: $(cat "$2/error")"
}

# 5. An empty commit on a branch this workflow did not generate.
fixture="$(make_fixture foreign-branch)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "feature/unrelated"
refused "foreign branch" "$fixture" "$base" "refusing to discard unexpected branch"

# 6. The remote branch moved after the action pushed.
fixture="$(make_fixture remote-moved)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
refused "remote moved" "$fixture" "$base" "generated remote branch moved"

# 7. The open pull request is at another commit than the one this run pushed.
fixture="$(make_fixture pr-mismatch)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS="$(pull_list "$branch" cccccccccccccccccccccccccccccccccccccccc)"
refused "pull request mismatch" "$fixture" "$base" "does not match the commit this run pushed"

# 8. The pull-request listing is not a list.
fixture="$(make_fixture pr-invalid)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS='{"message":"Not Found"}'
refused "invalid listing" "$fixture" "$base" "does not match the commit this run pushed"

# 9. The base is not an ancestor of the commit being discarded.
fixture="$(make_fixture unrelated-base)"
git -C "$fixture/repo" switch -q --orphan other
printf 'base\n' >"$fixture/repo/file.txt"
git -C "$fixture/repo" add file.txt
git -C "$fixture/repo" commit -q -m "same tree, unrelated history"
other="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" switch -q main
sync_commit "$fixture" "$branch"
refused "unrelated base" "$fixture" "$other" "does not descend from the workflow base sha"

# 10. A pull request that will not close keeps its branch.
fixture="$(make_fixture close-fails)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS="$(pull_list "$branch" "$REMOTE_SHA")"
FAKE_GH_MODE=close-fails
run_helper "$fixture" "$base"
FAKE_GH_MODE=success
[[ "$rc" -ne 0 ]] || fail "close fails — the helper reported success"
[[ -z "$(cat "$fixture/output")" ]] || fail "close fails — the helper still printed a result"
if grep -q '^DELETE ' "$fixture/gh.log"; then
  fail "close fails — the branch was deleted although its pull request stayed open"
fi

# 11. A pull request GitHub still reports open keeps its branch too.
fixture="$(make_fixture stays-open)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
sync_commit "$fixture" "$branch"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS="$(pull_list "$branch" "$REMOTE_SHA")"
FAKE_GH_MODE=stays-open
run_helper "$fixture" "$base"
FAKE_GH_MODE=success
[[ "$rc" -ne 0 ]] || fail "stays open — the helper reported success"
if grep -q '^DELETE ' "$fixture/gh.log"; then
  fail "stays open — the branch was deleted although its pull request stayed open"
fi

echo "PASS: an empty template sync loses its pull request and branch, and a real one is left alone"
