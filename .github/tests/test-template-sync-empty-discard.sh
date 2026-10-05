#!/usr/bin/env bash

# A template sync that would change nothing must not leave an open pull request (#467).
#
# The sync action opens its pull request before the signing helper runs. When the template lags
# the consumer on a catalogue pin, the signing helper restores the consumer's line and the result
# can equal the base (wedding-app#377, ascoachingogvaner#280: one pin, template behind). This
# drives the real signing helper and the real discard helper against git fixtures and an offline
# `gh`: the measured case must be closed and never signed, and a real sync must still be signed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
signer="$repo_root/.github/scripts/replace-template-sync-commit.sh"
helper="$repo_root/.github/scripts/discard-empty-template-sync.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$signer" ]] || fail "template-sync signing helper is missing or not executable"
[[ -x "$helper" ]] || fail "empty-sync helper is missing or not executable"

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

branch="chore/template-sync_deadbee"
newer="1111111111111111111111111111111111111111"
older="2222222222222222222222222222222222222222"
export SIGNED_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# caller <file> <sha>: a workflow that calls one catalogue workflow at that pin.
caller() {
  mkdir -p "$(dirname "$1")"
  printf 'name: fixture\non: push\njobs:\n  call:\n    uses: devantler-tech/.github/.github/workflows/publish-app.yaml@%s # pin\n' \
    "$2" >"$1"
}

# make_fixture <name>: a consumer repository whose base pins the newer commit; prints its path.
make_fixture() {
  local fixture="$test_root/$1"
  mkdir -p "$fixture/bin" "$fixture/repo"

  git -C "$fixture/repo" init -q -b main
  git -C "$fixture/repo" config user.name "Test User"
  git -C "$fixture/repo" config user.email "test@example.com"
  git -C "$fixture/repo" config commit.gpgsign false
  caller "$fixture/repo/.github/workflows/release.yaml" "$newer"
  printf 'base\n' >"$fixture/repo/file.txt"
  git -C "$fixture/repo" add -A
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
  "GET repos/devantler-tech/.github/compare/1111111111111111111111111111111111111111...2222222222222222222222222222222222222222")
    echo '{"status":"behind"}'
    ;;
  "GET repos/example/consumer/git/ref/heads/chore/template-sync_deadbee")
    if [[ -f "$FAKE_GH_UPDATED" ]]; then
      jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
    else
      jq -n --arg sha "$REMOTE_SHA" '{object:{sha:$sha}}'
    fi
    ;;
  "GET repos/example/consumer/pulls?state=open&head=example:chore/template-sync_deadbee&per_page=100")
    printf '%s\n' "$FAKE_PULLS"
    ;;
  "POST repos/example/consumer/issues/41/comments")
    jq -e '.body | test("would change no files")' >/dev/null || exit 94
    [[ "$FAKE_GH_MODE" != "comment-fails" ]] || exit 1
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
  "PATCH repos/example/consumer/git/refs/heads/chore/template-sync_deadbee")
    payload="$(cat)"
    if jq -e --arg sha "$BASE_SHA" '. == {sha:$sha,force:true}' <<<"$payload" >/dev/null; then
      printf 'PATCH-REF base\n' >>"$FAKE_GH_LOG"
      if [[ "$FAKE_GH_MODE" == "ref-elsewhere" ]]; then
        echo '{"object":{"sha":"dddddddddddddddddddddddddddddddddddddddd"}}'
        exit 0
      fi
      jq -n --arg sha "$BASE_SHA" '{object:{sha:$sha}}'
    else
      # The signing helper publishing a verified commit: only a real sync may get here.
      jq -e --arg sha "$SIGNED_SHA" '. == {sha:$sha,force:true}' <<<"$payload" >/dev/null || exit 97
      printf 'PATCH-REF signed\n' >>"$FAKE_GH_LOG"
      : >"$FAKE_GH_UPDATED"
      jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
    fi
    ;;
  "POST repos/example/consumer/git/trees")
    # Build the tree the way GitHub does: the base tree with each posted blob written over it.
    payload="$(cat)"
    index="$(mktemp)"
    GIT_INDEX_FILE="$index" git read-tree "$(jq -er '.base_tree' <<<"$payload")"
    count="$(jq '.tree | length' <<<"$payload")"
    for ((i = 0; i < count; i++)); do
      entry="$(jq -c ".tree[$i]" <<<"$payload")"
      blob="$(jq -j '.content' <<<"$entry" | git hash-object -w --stdin)"
      GIT_INDEX_FILE="$index" git update-index --add \
        --cacheinfo "$(jq -r '.mode' <<<"$entry"),$blob,$(jq -r '.path' <<<"$entry")"
    done
    jq -n --arg sha "$(GIT_INDEX_FILE="$index" git write-tree)" '{sha:$sha}'
    rm -f "$index"
    ;;
  "POST repos/example/consumer/git/commits")
    payload="$(cat)"
    jq -n --arg sha "$SIGNED_SHA" '{sha:$sha,verification:{verified:true,reason:"valid"}}'
    printf '%s\n' "$payload" >"$FAKE_GH_COMMIT"
    ;;
  "GET repos/example/consumer/commits/$SIGNED_SHA")
    jq --arg sha "$SIGNED_SHA" \
      '{sha:$sha,commit:{message:.message,tree:{sha:.tree},verification:{verified:true}},parents:[{sha:.parents[0]}]}' \
      "$FAKE_GH_COMMIT"
    ;;
  *)
    exit 96
    ;;
esac
FAKE_GH
  chmod +x "$fixture/bin/gh"
  printf '%s\n' "$fixture"
}

# sync_commit <fixture> <branch> <kind>: what the sync action pushed.
#   downgrade  only the pin moves back to the older commit (the measured case)
#   mixed      the pin moves back and another file changes
#   empty      no change at all
sync_commit() {
  git -C "$1/repo" switch -q -c "$2"
  case "$3" in
    downgrade) caller "$1/repo/.github/workflows/release.yaml" "$older" ;;
    mixed)
      caller "$1/repo/.github/workflows/release.yaml" "$older"
      printf 'synced\n' >"$1/repo/file.txt"
      ;;
    empty) ;;
    *) fail "unknown sync kind $3" ;;
  esac
  git -C "$1/repo" add -A
  git -C "$1/repo" commit -q --allow-empty -m "chore: sync changes from the upstream template"
}

# run <fixture> <script> [args...]: status in $rc, stdout in output, stderr in error, calls in gh.log.
run() {
  local fixture="$1"
  shift
  rc=0
  (
    cd "$fixture/repo"
    PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=example/consumer FAKE_GH_LOG="$fixture/gh.log" \
      FAKE_GH_UPDATED="$fixture/updated" FAKE_GH_COMMIT="$fixture/commit.json" "$@"
  ) >"$fixture/output" 2>"$fixture/error" || rc=$?
}

run_signer() {
  run "$1" "$signer" --base-sha "$2" --branch-prefix chore/template-sync
}

# The writes a run made, in order; the ref update is named by what it published.
writes() {
  [[ -e "$1/gh.log" ]] || return 0
  grep -vE "^(GET |PATCH repos/example/consumer/git/refs/)" "$1/gh.log" || true
}

pull_list() {
  jq -cn --arg ref "$1" --arg sha "$2" '[{number:41,head:{ref:$ref,sha:$sha}}]'
}

# prepare <name> <kind> [branch]: fixture, base and remote state for one sync; sets fixture, base.
prepare() {
  fixture="$(make_fixture "$1")"
  base="$(git -C "$fixture/repo" rev-parse HEAD)"
  sync_commit "$fixture" "${3:-$branch}" "$2"
  REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
  FAKE_PULLS="$(pull_list "$branch" "$REMOTE_SHA")"
  BASE_SHA="$base"
  export REMOTE_SHA FAKE_PULLS BASE_SHA
}

discard_writes="PATCH-REF base
POST repos/example/consumer/issues/41/comments
PATCH repos/example/consumer/pulls/41"

export FAKE_GH_MODE=success

# 1. The measured case: the template lags on one pin, so the corrected result equals the base.
prepare downgrade downgrade
run_signer "$fixture" "$base"
[[ "$rc" -eq 0 ]] || fail "downgrade — the signing helper failed: $(cat "$fixture/error")"
[[ "$(cat "$fixture/output")" == "discarded" ]] ||
  fail "downgrade — expected 'discarded', got '$(cat "$fixture/output")'"
[[ "$(writes "$fixture")" == "$discard_writes" ]] ||
  fail "downgrade — expected branch back on base, comment, close and nothing signed, got: $(writes "$fixture")"
grep -q '^::warning file=\.github/workflows/release\.yaml' "$fixture/error" ||
  fail "downgrade — the omitted pin was not reported"

# 2. A sync commit with no change at all is discarded the same way.
prepare empty empty
run_signer "$fixture" "$base"
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "discarded" ]] ||
  fail "empty — expected 'discarded': $(cat "$fixture/error")"
[[ "$(writes "$fixture")" == "$discard_writes" ]] || fail "empty — unexpected writes: $(writes "$fixture")"

# 3. A real sync that also carries a lagging pin is still signed, and nothing is closed.
prepare mixed mixed
run_signer "$fixture" "$base"
[[ "$rc" -eq 0 ]] || fail "mixed — the signing helper failed: $(cat "$fixture/error")"
[[ "$(cat "$fixture/output")" == "$SIGNED_SHA" ]] ||
  fail "mixed — expected the signed sha, got '$(cat "$fixture/output")'"
expected_real="POST repos/example/consumer/git/trees
POST repos/example/consumer/git/commits
PATCH-REF signed"
[[ "$(writes "$fixture")" == "$expected_real" ]] || fail "mixed — a real sync was not signed as before: $(writes "$fixture")"

# 4. An empty sync whose pull request is already gone still gets its branch moved.
prepare empty-no-pr downgrade
FAKE_PULLS='[]'
run_signer "$fixture" "$base"
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "discarded" ]] ||
  fail "no pull request — expected 'discarded': $(cat "$fixture/error")"
[[ "$(writes "$fixture")" == "PATCH-REF base" ]] ||
  fail "no pull request — expected only the branch move, got: $(writes "$fixture")"

# refused <case> <error pattern>: the last run failed, wrote nothing and named its reason.
refused() {
  [[ "$rc" -ne 0 ]] || fail "$1 — the helper discarded anyway"
  [[ -z "$(cat "$fixture/output")" ]] || fail "$1 — a refusal still printed a result: $(cat "$fixture/output")"
  [[ -z "$(writes "$fixture")" ]] || fail "$1 — a refusal still wrote: $(writes "$fixture")"
  grep -q "$2" "$fixture/error" || fail "$1 — the refusal did not name its reason: $(cat "$fixture/error")"
}

run_helper() {
  run "$1" "$helper" --base-sha "$2" --branch-prefix chore/template-sync --tree "$3"
}

# 5. The discard helper refuses a proposal that is not empty.
prepare not-empty mixed
run_helper "$fixture" "$base" "$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
refused "real sync" "refusing to discard a real sync"

# 6. An empty proposal on a branch this workflow did not generate.
prepare foreign-branch empty feature/unrelated
run_helper "$fixture" "$base" "$(git -C "$fixture/repo" rev-parse "$base^{tree}")"
refused "foreign branch" "refusing to discard unexpected branch"

# 7. The remote branch moved after the action pushed.
prepare remote-moved downgrade
REMOTE_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
run_helper "$fixture" "$base" "$(git -C "$fixture/repo" rev-parse "$base^{tree}")"
refused "remote moved" "generated remote branch moved"

# 8. The open pull request is at another commit than the one this run pushed.
prepare pr-mismatch downgrade
FAKE_PULLS="$(pull_list "$branch" cccccccccccccccccccccccccccccccccccccccc)"
run_signer "$fixture" "$base"
refused "pull request mismatch" "does not match the commit this run pushed"

# 9. The pull-request listing is not a list.
prepare pr-invalid downgrade
FAKE_PULLS='{"message":"Not Found"}'
run_signer "$fixture" "$base"
refused "invalid listing" "does not match the commit this run pushed"

# 10. The base is not an ancestor of the commit being discarded.
fixture="$(make_fixture unrelated-base)"
git -C "$fixture/repo" switch -q --orphan other
caller "$fixture/repo/.github/workflows/release.yaml" "$newer"
printf 'base\n' >"$fixture/repo/file.txt"
git -C "$fixture/repo" add -A
git -C "$fixture/repo" commit -q -m "same tree, unrelated history"
other="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" switch -q main
sync_commit "$fixture" "$branch" empty
run_helper "$fixture" "$other" "$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
refused "unrelated base" "does not descend from the workflow base sha"

# 11. No sync commit exists.
fixture="$(make_fixture no-commit)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
run_helper "$fixture" "$base" "$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
refused "no commit" "no sync commit was created"

# proposal_gone <case> <mode>: a later failure is reported, but the branch is already off the proposal.
proposal_gone() {
  prepare "$2" downgrade
  FAKE_GH_MODE="$2"
  run_signer "$fixture" "$base"
  FAKE_GH_MODE=success
  [[ "$rc" -ne 0 ]] || fail "$1 — the helper reported success"
  [[ -z "$(cat "$fixture/output")" ]] || fail "$1 — the helper still printed a result"
  grep -qx 'PATCH-REF base' "$fixture/gh.log" ||
    fail "$1 — the branch still carries the unsigned proposal"
  if grep -qE '^(PATCH-REF signed|POST repos/example/consumer/git/commits)$' "$fixture/gh.log"; then
    fail "$1 — the empty proposal was signed"
  fi
}

# 12–14. The comment fails, the close request fails, or GitHub still reports the pull request open.
proposal_gone "comment fails" comment-fails
proposal_gone "close fails" close-fails
proposal_gone "stays open" stays-open

# 15. A branch update GitHub answers with another commit stops before the pull request is touched.
prepare ref-elsewhere downgrade
FAKE_GH_MODE=ref-elsewhere
run_signer "$fixture" "$base"
FAKE_GH_MODE=success
[[ "$rc" -ne 0 ]] || fail "branch elsewhere — the helper reported success"
[[ -z "$(cat "$fixture/output")" ]] || fail "branch elsewhere — the helper still printed a result"
[[ "$(writes "$fixture")" == "PATCH-REF base" ]] || fail "branch elsewhere — the pull request was touched: $(writes "$fixture")"

# 16. With a merged ignore list, the proposal still changes the ignore file: signed, not discarded.
fixture="$(make_fixture pre-sync)"
base="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" switch -q -c "$branch"
printf 'docs/\n' >"$fixture/repo/.templatesyncignore"
git -C "$fixture/repo" add -A
git -C "$fixture/repo" commit -q -m "chore: merge the template's ignore entries"
pre_sync="$(git -C "$fixture/repo" rev-parse HEAD)"
caller "$fixture/repo/.github/workflows/release.yaml" "$older"
git -C "$fixture/repo" add -A
git -C "$fixture/repo" commit -q -m "chore: sync changes from the upstream template"
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
FAKE_PULLS="$(pull_list "$branch" "$REMOTE_SHA")"
BASE_SHA="$base"
run "$fixture" "$signer" --base-sha "$base" --branch-prefix chore/template-sync \
  --pre-sync-sha "$pre_sync" --pre-sync-path .templatesyncignore
[[ "$rc" -eq 0 && "$(cat "$fixture/output")" == "$SIGNED_SHA" ]] ||
  fail "pre-sync — an ignore-list change was not signed: $(cat "$fixture/output") $(cat "$fixture/error")"
[[ "$(writes "$fixture")" == "$expected_real" ]] || fail "pre-sync — unexpected writes: $(writes "$fixture")"

echo "PASS: a template sync that would change nothing is closed and never signed, and a real one is signed as before"
