#!/usr/bin/env bash
# Independent regressions must fail the signed-fixes reference test for the intended reason, and a
# release that leaves the reviewed workflow untouched must pass with no edit to that test (#484).
#
# Every case runs against a throwaway source repository, so nothing here needs the network:
#   reviewed  a commit carrying the reviewed apply-signed-fixes.yaml (same content, same blob id)
#   release   a later commit that changes another file only -- the unchanged-workflow release
#   changed   a later commit that changes apply-signed-fixes.yaml -- the release needing a review
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
cp "$root/$signed_fixes_path" "$work/source/$signed_fixes_path"
fixture_git add "$signed_fixes_path"
fixture_git commit --quiet -m reviewed
reviewed="$(fixture_git rev-parse HEAD)"
echo release >"$work/source/RELEASE"
fixture_git add RELEASE
fixture_git commit --quiet -m release
release="$(fixture_git rev-parse HEAD)"
echo '# changed' >>"$work/source/$signed_fixes_path"
fixture_git add "$signed_fixes_path"
fixture_git commit --quiet -m changed
changed="$(fixture_git rev-parse HEAD)"
fixture_git config uploadpack.allowFilter true
fixture_git config uploadpack.allowAnySHA1InWant true

# The real workflow, with its three callers repointed at the fixture's reviewed commit.
callers='(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)'
prefix="devantler-tech/.github/${signed_fixes_path}"
yq -o=json '.' "$root/.github/workflows/validate-go-project.yaml" |
  jq --arg ref "${prefix}@${reviewed}" "${callers} = \$ref" >"$work/baseline.json"

run_guard() { # <directory holding the git objects> <workflow> [source remote]
  (
    cd "$1"
    SIGNED_FIXES_SOURCE_REMOTE="${3:-$work/absent-remote}" bash "$guard" "$2"
  )
}

expect_pass() { # <label> <jq mutation> [directory] [source remote]
  jq --arg prefix "$prefix" --arg release "$release" --arg changed "$changed" \
    "$2" "$work/baseline.json" >"$work/mutated.json"
  run_guard "${3:-$work/source}" "$work/mutated.json" "${4:-}" >"$work/result" 2>&1 || {
    cat "$work/result" >&2
    fail "$1 was rejected"
  }
  echo "PASS: accepts $1"
}

expect_pass 'the reviewed commit' '.'
expect_pass 'a release that leaves the reviewed workflow unchanged' "${callers} = \$prefix + \"@\" + \$release"

# A shallow consumer checkout holds none of the source commits, so the guard must fetch the one it
# was pointed at, and only that one.
git init --quiet "$work/shallow"
expect_pass 'an unchanged release it has to fetch' "${callers} = \$prefix + \"@\" + \$release" \
  "$work/shallow" "file://$work/source"

cases=0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq --arg prefix "$prefix" --arg release "$release" --arg changed "$changed" \
    "$mutation" "$work/baseline.json" >"$work/mutated.json"
  if run_guard "$work/source" "$work/mutated.json" >"$work/result" 2>&1; then
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
abbreviated commit	.jobs."apply-fixes".uses=$prefix+"@"+$release[0:12]	at a full commit
uppercase commit	.jobs."apply-fixes".uses=$prefix+"@"+($release|ascii_upcase)	at a full commit
trailing text after the commit	.jobs."apply-fixes".uses=$prefix+"@"+$release+"\n"	at a full commit
foreign repository	.jobs."apply-fixes".uses="outside/fixture/.github/workflows/apply-signed-fixes.yaml@"+$release	at a full commit
look-alike repository	.jobs."apply-fixes".uses="devantler-tech/xgithub/.github/workflows/apply-signed-fixes.yaml@"+$release	at a full commit
other workflow path	.jobs."apply-fixes".uses="devantler-tech/.github/.github/workflows/validate-go-project.yaml@"+$release	at a full commit
missing call	del(.jobs."apply-tidy-fixes".uses)	at a full commit
callers that disagree	.jobs."apply-fixes".uses=$prefix+"@"+$release	all three must name one reference
changed workflow content	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@"+$changed	but the reviewed content is blob
unreadable commit	(.jobs."apply-tidy-fixes".uses, .jobs."apply-golangci-lint-fixes".uses, .jobs."apply-fixes".uses)=$prefix+"@0123456789abcdef0123456789abcdef01234567"	the reference stays unverified
CASES

# A failed fetch must not be mistaken for a missing file, and a reachable source must not rescue a
# commit it does not hold.
jq --arg prefix "$prefix" "${callers} = \$prefix + \"@0123456789abcdef0123456789abcdef01234567\"" \
  "$work/baseline.json" >"$work/mutated.json"
if run_guard "$work/shallow" "$work/mutated.json" "file://$work/source" >"$work/result" 2>&1; then
  fail 'a commit the source does not hold was accepted'
fi
grep -qF 'the reference stays unverified' "$work/result" || {
  cat "$work/result" >&2
  fail 'a commit the source does not hold failed for the wrong reason'
}
echo 'PASS: rejects a commit the source does not hold'

# The failure for changed content must print both blob ids, so the reviewer knows what to record.
jq --arg prefix "$prefix" --arg changed "$changed" "${callers} = \$prefix + \"@\" + \$changed" \
  "$work/baseline.json" >"$work/mutated.json"
run_guard "$work/source" "$work/mutated.json" >"$work/result" 2>&1 && fail 'changed content was accepted'
for blob in "$(fixture_git rev-parse "${changed}:${signed_fixes_path}")" \
  "$(fixture_git rev-parse "${reviewed}:${signed_fixes_path}")"; do
  grep -qF "blob ${blob}" "$work/result" || {
    cat "$work/result" >&2
    fail "the changed-content failure does not name blob ${blob}"
  }
done
echo 'PASS: the changed-content failure names both blob ids'

[[ "$cases" -eq 13 ]] || fail "expected 13 rejected mutations, ran ${cases}"
echo 'PASS: 13 independent signed-fixes reference mutations are rejected'
