#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/.github/scripts/replace-template-sync-commit.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$helper" ]] || fail "template-sync signing helper is missing or not executable"

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

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
    -X|--method)
      method="$2"
      shift 2
      ;;
    --input)
      [[ "$2" == "-" ]] || exit 92
      shift 2
      ;;
    -H|--header)
      shift 2
      ;;
    --*)
      shift
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
    if [[ -f "$FAKE_GH_UPDATED" ]]; then
      # After the update, serve the previous commit for the first FAKE_GH_STALE_READS reads.
      stale_seen=0
      if [[ -f "$FAKE_GH_UPDATED.reads" ]]; then
        stale_seen="$(cat "$FAKE_GH_UPDATED.reads")"
      fi
      if ((stale_seen < ${FAKE_GH_STALE_READS:-0})); then
        printf '%s\n' "$((stale_seen + 1))" >"$FAKE_GH_UPDATED.reads"
        jq -n --arg sha "$REMOTE_SHA" '{object:{sha:$sha}}'
      else
        jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
      fi
    else
      jq -n --arg sha "$REMOTE_SHA" '{object:{sha:$sha}}'
    fi
    ;;
  "POST repos/example/consumer/git/commits")
    payload="$(cat)"
    jq -e \
      --arg tree "$EXPECTED_TREE" \
      --arg parent "$EXPECTED_PARENT" \
      --arg message "$EXPECTED_MESSAGE" \
      '.tree == $tree
       and .parents == [$parent]
       and .message == $message
       and (has("author") | not)
       and (has("committer") | not)
       and (has("signature") | not)' \
      <<<"$payload" >/dev/null || exit 94
    if [[ "$FAKE_GH_MODE" == "unsigned" ]]; then
      jq -n --arg sha "$SIGNED_SHA" '{sha:$sha,verification:{verified:false,reason:"unsigned"}}'
    else
      jq -n --arg sha "$SIGNED_SHA" '{sha:$sha,verification:{verified:true,reason:"valid"}}'
    fi
    ;;
  "PATCH repos/example/consumer/git/refs/heads/chore/template-sync_deadbee")
    payload="$(cat)"
    jq -e --arg sha "$SIGNED_SHA" '.sha == $sha and .force == true' <<<"$payload" >/dev/null || exit 95
    : >"$FAKE_GH_UPDATED"
    jq -n --arg sha "$SIGNED_SHA" '{object:{sha:$sha}}'
    ;;
  "GET repos/example/consumer/commits/$SIGNED_SHA")
    jq -n \
      --arg sha "$SIGNED_SHA" \
      --arg tree "$EXPECTED_TREE" \
      --arg parent "$EXPECTED_PARENT" \
      --arg message "$EXPECTED_MESSAGE" \
      '{sha:$sha,commit:{message:$message,tree:{sha:$tree},verification:{verified:true,reason:"valid"}},parents:[{sha:$parent}]}'
    ;;
  *)
    exit 96
    ;;
esac
FAKE_GH
  chmod +x "$fixture/bin/gh"
  printf '%s\n' "$fixture"
}

export SIGNED_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fixture="$(make_fixture success)"
base_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" switch -q -c chore/template-sync_deadbee
printf 'synced\n' >"$fixture/repo/file.txt"
git -C "$fixture/repo" add file.txt
git -C "$fixture/repo" commit -q -m $'chore: sync template\n\nSigned-off-by: bot <bot@example.com>'

EXPECTED_TREE="$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
export EXPECTED_TREE
export EXPECTED_PARENT="$base_sha"
EXPECTED_MESSAGE="$(git -C "$fixture/repo" log -1 --format=%B | sed '${/^$/d;}')"
export EXPECTED_MESSAGE
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
export REMOTE_SHA
export FAKE_GH_LOG="$fixture/gh.log"
export FAKE_GH_UPDATED="$fixture/updated"
export FAKE_GH_MODE=success

(
  cd "$fixture/repo"
  PATH="$fixture/bin:$PATH" \
    GITHUB_REPOSITORY=example/consumer \
    "$helper" --base-sha "$base_sha" --branch-prefix chore/template-sync
) >"$fixture/output"

grep -qx "$SIGNED_SHA" "$fixture/output" || fail "helper did not return the verified replacement sha"
[[ -f "$FAKE_GH_UPDATED" ]] || fail "helper did not update the generated branch"
grep -qx "PATCH repos/example/consumer/git/refs/heads/chore/template-sync_deadbee" "$FAKE_GH_LOG" ||
  fail "helper did not update the exact generated branch"
grep -qx "GET repos/example/consumer/commits/$SIGNED_SHA" "$FAKE_GH_LOG" ||
  fail "helper did not verify the replacement commit after updating the ref"

fixture="$(make_fixture unsigned)"
base_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" switch -q -c chore/template-sync_deadbee
printf 'synced\n' >"$fixture/repo/file.txt"
git -C "$fixture/repo" add file.txt
git -C "$fixture/repo" commit -q -m "chore: sync template"

EXPECTED_TREE="$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
export EXPECTED_TREE
export EXPECTED_PARENT="$base_sha"
EXPECTED_MESSAGE="$(git -C "$fixture/repo" log -1 --format=%B | sed '${/^$/d;}')"
export EXPECTED_MESSAGE
REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
export REMOTE_SHA
export FAKE_GH_LOG="$fixture/gh.log"
export FAKE_GH_UPDATED="$fixture/updated"
export FAKE_GH_MODE=unsigned

if (
  cd "$fixture/repo"
  PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=example/consumer \
    "$helper" --base-sha "$base_sha" --branch-prefix chore/template-sync
) >"$fixture/output" 2>"$fixture/error"; then
  fail "helper accepted an unsigned API commit"
fi
[[ ! -f "$FAKE_GH_UPDATED" ]] || fail "helper moved the ref before signature verification passed"
grep -q "GitHub did not verify" "$fixture/error" || fail "unsigned failure did not name the verification gate"

# A branch read that is stale once after the update, then current, still succeeds (#897).
run_readback_case() { # <name> <stale reads> -> runs the helper; output and error land in the fixture
  fixture="$(make_fixture "$1")"
  base_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
  git -C "$fixture/repo" switch -q -c chore/template-sync_deadbee
  printf 'synced\n' >"$fixture/repo/file.txt"
  git -C "$fixture/repo" add file.txt
  git -C "$fixture/repo" commit -q -m "chore: sync template"
  EXPECTED_TREE="$(git -C "$fixture/repo" rev-parse 'HEAD^{tree}')"
  export EXPECTED_TREE
  export EXPECTED_PARENT="$base_sha"
  EXPECTED_MESSAGE="$(git -C "$fixture/repo" log -1 --format=%B | sed '${/^$/d;}')"
  export EXPECTED_MESSAGE
  REMOTE_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
  export REMOTE_SHA
  export FAKE_GH_LOG="$fixture/gh.log"
  export FAKE_GH_UPDATED="$fixture/updated"
  export FAKE_GH_MODE=success
  export FAKE_GH_STALE_READS="$2"
  (
    cd "$fixture/repo"
    PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=example/consumer \
      "$helper" --base-sha "$base_sha" --branch-prefix chore/template-sync
  ) >"$fixture/output" 2>"$fixture/error"
}
# Count the branch reads the helper made after it moved the branch.
reads_after_update() {
  awk '/^PATCH / { seen = 1; next } seen && /^GET repos\/example\/consumer\/git\/ref\/heads\// { n++ } END { print n + 0 }' "$FAKE_GH_LOG"
}

run_readback_case stale-once 1 || fail "helper failed although the branch read was stale only once"
grep -qx "$SIGNED_SHA" "$fixture/output" || fail "stale-once readback did not return the verified replacement sha"
[[ "$(reads_after_update)" == 2 ]] || fail "stale-once readback did not read the branch exactly twice"

# A branch that keeps pointing at another commit still fails, after the bounded retries.
if run_readback_case never-current 99; then
  fail "helper accepted a branch that never pointed at the verified replacement"
fi
grep -q "generated branch does not point to the verified replacement" "$fixture/error" ||
  fail "persistent readback mismatch did not name the branch gate"
[[ "$(reads_after_update)" == 5 ]] || fail "persistent readback mismatch was not read exactly five times"
unset FAKE_GH_STALE_READS

fixture="$(make_fixture no-change)"
base_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
export FAKE_GH_LOG="$fixture/gh.log"
export FAKE_GH_UPDATED="$fixture/updated"
export FAKE_GH_MODE=success

(
  cd "$fixture/repo"
  PATH="$fixture/bin:$PATH" GITHUB_REPOSITORY=example/consumer \
    "$helper" --base-sha "$base_sha" --branch-prefix chore/template-sync
) >"$fixture/output"
[[ ! -e "$FAKE_GH_LOG" ]] || fail "no-change path called the GitHub API"
grep -q "No template-sync commit" "$fixture/output" || fail "no-change path did not report its safe skip"

echo "PASS: template-sync preserves the exact commit content, verifies the App signature, and updates only the generated branch"
