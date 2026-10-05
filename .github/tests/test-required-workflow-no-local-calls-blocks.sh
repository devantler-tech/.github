#!/usr/bin/env bash
# Independent regressions must fail the signed-fixes reference test for the intended reason, and a
# release that leaves the reviewed workflow untouched must pass with no edit to that test (#484).
#
# Every case runs against a throwaway source repository, so nothing here needs the network:
#   reviewed  a commit carrying the fixture's reviewed workflow
#   release   a later commit that changes another file only -- the unchanged-workflow release
#   changed   a later commit that changes the workflow -- the release needing a review
#
# The guard records two facts about the real repository: where it lives and which workflow content
# was reviewed. This suite tests the guard's LOGIC, so it runs a copy of the guard in which exactly
# those two lines name the fixture instead. The fixture workflow is this suite's own text, never the
# repository's current file: a pull request that edits the real workflow must still be able to pass
# here while the real guard keeps judging the release the callers pin.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/.github/tests/test-required-workflow-no-local-calls.sh"
signed_fixes_path='.github/workflows/apply-signed-fixes.yaml'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fixture_git() {
  git -C "$work/source" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false "$@"
}

git init --quiet "$work/source"
mkdir -p "$work/source/.github/workflows"
echo 'reviewed fixture workflow' >"$work/source/$signed_fixes_path"
fixture_git add "$signed_fixes_path"
fixture_git commit --quiet -m reviewed
reviewed="$(fixture_git rev-parse HEAD)"
reviewed_blob="$(fixture_git rev-parse "HEAD:${signed_fixes_path}")"
echo release >"$work/source/RELEASE"
fixture_git add RELEASE
fixture_git commit --quiet -m release
release="$(fixture_git rev-parse HEAD)"
echo 'changed fixture workflow' >"$work/source/$signed_fixes_path"
fixture_git add "$signed_fixes_path"
fixture_git commit --quiet -m changed
changed="$(fixture_git rev-parse HEAD)"
changed_blob="$(fixture_git rev-parse "HEAD:${signed_fixes_path}")"
fixture_git config uploadpack.allowFilter true
fixture_git config uploadpack.allowAnySHA1InWant true

# The guard copy: the same script with its two recorded facts pointed at the fixture.
[[ "$(grep -c "^reviewed_blob='[0-9a-f]\{40\}'\$" "$guard")" -eq 1 ]] ||
  fail 'the guard must record the reviewed blob id on exactly one line'
[[ "$(grep -c "^source_remote='https://github.com/devantler-tech/.github.git'\$" "$guard")" -eq 1 ]] ||
  fail 'the guard must record the source repository on exactly one line'
make_guard() { # <source remote> <output>
  sed -e "s|^reviewed_blob='.*'\$|reviewed_blob='${reviewed_blob}'|" \
    -e "s|^source_remote='.*'\$|source_remote='$1'|" "$guard" >"$2"
}
make_guard "$work/absent-remote" "$work/guard-offline.sh"
make_guard "file://$work/source" "$work/guard-fetching.sh"

# The real workflow, with its three callers repointed at the fixture's reviewed commit.
callers='(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)'
prefix="devantler-tech/.github/${signed_fixes_path}"
yq -o=json '.' "$root/.github/workflows/validate-go-project.yaml" |
  jq --arg ref "${prefix}@${reviewed}" "${callers} = \$ref" >"$work/baseline.json"

mutate() { # <jq mutation>
  jq --arg prefix "$prefix" --arg release "$release" --arg changed "$changed" \
    "$1" "$work/baseline.json" >"$work/mutated.json"
}

run_guard() { # <guard copy> <directory to run in>
  (
    cd "$2"
    "$BASH" "$1" "$work/mutated.json"
  )
}

expect_pass() { # <label> <jq mutation> <guard copy> <directory to run in>
  mutate "$2"
  run_guard "$3" "$4" >"$work/result" 2>&1 || {
    cat "$work/result" >&2
    fail "$1 was rejected"
  }
  echo "PASS: accepts $1"
}

expect_pass 'the reviewed commit' '.' "$work/guard-offline.sh" "$work/source"
expect_pass 'a release that leaves the reviewed workflow unchanged' \
  "${callers} = \$prefix + \"@\" + \$release" "$work/guard-offline.sh" "$work/source"

# A consumer checkout holds none of the source commits, so the guard must fetch the one it was
# pointed at -- and must leave the checkout it runs in exactly as it found it.
git init --quiet "$work/consumer"
snapshot() {
  (
    cd "$work/consumer"
    find .git -type f ! -name '*.sample' | LC_ALL=C sort | xargs cksum
  )
}
snapshot >"$work/before"
expect_pass 'an unchanged release it has to fetch' \
  "${callers} = \$prefix + \"@\" + \$release" "$work/guard-fetching.sh" "$work/consumer"
snapshot >"$work/after"
cmp -s "$work/before" "$work/after" || {
  diff "$work/before" "$work/after" >&2 || true
  fail 'the guard changed the repository it ran in'
}
echo 'PASS: fetching leaves the repository it runs in untouched'

cases=0
while IFS=$'\t' read -r label mutation diagnostic; do
  mutate "$mutation"
  if run_guard "$work/guard-offline.sh" "$work/source" >"$work/result" 2>&1; then
    fail "$label was accepted"
  fi
  grep -qF -- "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    fail "$label failed for the wrong reason"
  }
  echo "PASS: rejects $label"
  cases=$((cases + 1))
done <<'CASES'
consumer-relative call	.jobs."apply-fixes".uses="./.github/workflows/apply-signed-fixes.yaml"	consumer-relative reusable-workflow calls
tag reference	.jobs."apply-tidy-fixes".uses=$prefix+"@v7.0.2"	at a full commit
branch reference	.jobs."apply-golangci-lint-fixes".uses=$prefix+"@main"	at a full commit
abbreviated commit	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@"+$release[0:12]	at a full commit
uppercase commit	.jobs."apply-fixes".uses=$prefix+"@"+($release|ascii_upcase)	at a full commit
trailing text after the commit	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@"+$release+"\n"	at a full commit
foreign repository	.jobs."apply-fixes".uses="outside/fixture/.github/workflows/apply-signed-fixes.yaml@"+$release	at a full commit
look-alike repository	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)="devantler-tech/xgithub/.github/workflows/apply-signed-fixes.yaml@"+$release	at a full commit
look-alike workflow path	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)="devantler-tech/.github/.github/workflows/apply-signed-fixesXyaml@"+$release	at a full commit
other workflow path	.jobs."apply-fixes".uses="devantler-tech/.github/.github/workflows/validate-go-project.yaml@"+$release	at a full commit
missing call	del(.jobs."apply-tidy-fixes".uses)	at a full commit
callers that disagree	.jobs."apply-fixes".uses=$prefix+"@"+$release	all three must name one reference
changed workflow content	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@"+$changed	but the reviewed content is blob
unreadable commit	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@0123456789abcdef0123456789abcdef01234567"	the reference stays unverified
CASES

# A failed fetch must not be mistaken for a missing file, and a reachable source must not rescue a
# commit it does not hold.
mutate "${callers} = \$prefix + \"@0123456789abcdef0123456789abcdef01234567\""
if run_guard "$work/guard-fetching.sh" "$work/consumer" >"$work/result" 2>&1; then
  fail 'a commit the source does not hold was accepted'
fi
grep -qF 'the reference stays unverified' "$work/result" || {
  cat "$work/result" >&2
  fail 'a commit the source does not hold failed for the wrong reason'
}
echo 'PASS: rejects a commit the source does not hold'

# A fetched commit is judged like a local one: changed content must not pass because it was fetched.
mutate "${callers} = \$prefix + \"@\" + \$changed"
if run_guard "$work/guard-fetching.sh" "$work/consumer" >"$work/result" 2>&1; then
  fail 'fetched changed content was accepted'
fi
# The failure for changed content must print both blob ids, so the reviewer knows what to record.
for blob in "$changed_blob" "$reviewed_blob"; do
  grep -qF "blob ${blob}" "$work/result" || {
    cat "$work/result" >&2
    fail "the changed-content failure does not name blob ${blob}"
  }
done
echo 'PASS: fetched changed content is rejected, and the failure names both blob ids'

[[ "$cases" -eq 14 ]] || fail "expected 14 rejected mutations, ran ${cases}"
echo 'PASS: 14 independent signed-fixes reference mutations are rejected'
