#!/usr/bin/env bash
# Pins the workflow execution inventory's classification against local fixtures, offline.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$repo_root/scripts/workflow-execution-inventory.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "workflow-execution-inventory test: $*" >&2
  exit 1
}

wf="$tmp/workflows"
mkdir "$wf"
printf 'on: push\njobs: {}\n' >"$wf/string.yaml"
printf 'on: [pull_request, merge_group]\njobs: {}\n' >"$wf/list.yml"
printf 'on:\n  pull_request_target:\n    types: [opened]\njobs: {}\n' >"$wf/target.yaml"
printf 'on:\n  workflow_run:\n    workflows: [CI]\njobs: {}\n' >"$wf/after-ci.yaml"
printf 'name: Publish Pages\non:\n  workflow_dispatch: {}\n  push:\n    branches: [main]\njobs: {}\n' >"$wf/pages.yaml"
printf 'on:\n  repository_dispatch:\n    types: [sync]\njobs: {}\n' >"$wf/sync.yaml"
printf 'on:\n  workflow_call: {}\njobs: {}\n' >"$wf/shared.yaml"
printf 'on:\n  schedule:\n    - cron: "0 0 * * *"\njobs: {}\n' >"$wf/nightly.yaml"
printf 'on:\n  push:\n    tags: ["v*"]\njobs: {}\n' >"$wf/cd.yaml"
# Content evidence, not names: a job bound to an environment deploys whatever the workflow is called.
printf 'on: push\njobs:\n  ship:\n    environment: production\n    runs-on: ubuntu-latest\n    steps: [{run: make}]\n' >"$wf/build.yaml"
printf 'on: push\njobs:\n  roll:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          helm upgrade --install app ./chart\n' >"$wf/roll.yaml"
printf 'on: push\npermissions:\n  packages: write\njobs:\n  image:\n    runs-on: ubuntu-latest\n    steps: [{run: make}]\n' >"$wf/image.yaml"
printf 'on: push\njobs:\n  sign:\n    permissions:\n      id-token: write\n    runs-on: ubuntu-latest\n    steps: [{run: make}]\n' >"$wf/sign.yaml"
printf 'on: push\njobs:\n  tag:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: goreleaser/goreleaser-action@v6\n' >"$wf/tag.yaml"
printf 'on: push\npermissions: write-all\njobs:\n  all:\n    runs-on: ubuntu-latest\n    steps: [{run: make}]\n' >"$wf/broad.yaml"
# A reusable-workflow call hides its steps, so a release-sounding caller stays unconfirmed.
printf 'name: Release\non: push\njobs:\n  call:\n    uses: ./.github/workflows/shared.yaml\n' >"$wf/release-caller.yaml"
# contents: write alone is also granted to bots that only commit, so it is not publication evidence.
printf 'on: push\npermissions:\n  contents: write\njobs:\n  fmt:\n    runs-on: ubuntu-latest\n    steps: [{run: make fmt}]\n' >"$wf/fmt.yaml"
printf 'on: push\njobs: {}\n' >"$wf/notes.txt"
printf 'on: push\njobs: {}\n' >"$wf/.dot.yml"

out="$(bash "$inventory" --dir "$wf" --repo fixture)" || fail "a fully parseable directory must exit 0"

expect() {
  local workflow="$1" events="$2" exposure="$3" row
  row="$(awk -F'\t' -v w="$workflow" '$2 == w' <<<"$out")"
  [ -n "$row" ] || fail "no row for $workflow"
  [ "$row" = "$(printf 'fixture\t%s\t%s\t%s\tn/a' "$workflow" "$events" "$exposure")" ] ||
    fail "$workflow: got '$row', want events='$events' exposure='$exposure'"
}

expect string.yaml push ci
expect list.yml merge_group,pull_request ci
expect target.yaml pull_request_target privileged-trigger
expect after-ci.yaml workflow_run privileged-trigger
expect pages.yaml push,workflow_dispatch manual-entry,release-unconfirmed
expect sync.yaml repository_dispatch manual-entry
expect shared.yaml workflow_call reusable
expect nightly.yaml schedule scheduled
expect cd.yaml push release-unconfirmed
expect .dot.yml push ci
expect build.yaml push deployment
expect roll.yaml push deployment
expect image.yaml push publication
expect sign.yaml push publication
expect tag.yaml push publication
expect broad.yaml push publication
expect release-caller.yaml push release-unconfirmed
expect fmt.yaml push ci

grep -q 'notes.txt' <<<"$out" && fail "a non-workflow file must not be inventoried"
[ "$(head -1 <<<"$out")" = "$(printf 'repo\tworkflow\tevents\texposure\trepo_policies')" ] ||
  fail "missing or wrong header"

# A workflow whose triggers cannot be read makes the whole inventory UNKNOWN, never complete.
printf 'jobs: {}\n' >"$wf/no-trigger.yaml"
rc=0
out="$(bash "$inventory" --dir "$wf" --repo fixture 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable workflow must exit 2, got $rc"
grep -q "$(printf 'no-trigger.yaml\tUNKNOWN\tUNKNOWN')" <<<"$out" ||
  fail "the unreadable workflow must be reported as UNKNOWN"

# A parser failure after partial output (a malformed later document) is UNKNOWN too.
rm "$wf/no-trigger.yaml"
printf 'on: push\njobs: {}\n---\non: [unclosed\n' >"$wf/multi.yaml"
rc=0
out="$(bash "$inventory" --dir "$wf" --repo fixture 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a partly parsed workflow must exit 2, got $rc"
grep -q "$(printf 'multi.yaml\tUNKNOWN\tUNKNOWN')" <<<"$out" ||
  fail "a partly parsed workflow must be reported as UNKNOWN, not by its first document"

# Two VALID documents are UNKNOWN as well: GitHub reads one workflow per file, so their merged
# events describe a workflow that does not exist.
printf 'on: push\njobs: {}\n---\non: workflow_dispatch\njobs: {}\n' >"$wf/multi.yaml"
rc=0
out="$(bash "$inventory" --dir "$wf" --repo fixture 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a multi-document workflow must exit 2, got $rc"
grep -q "$(printf 'multi.yaml\tUNKNOWN\tUNKNOWN')" <<<"$out" ||
  fail "a multi-document workflow must be reported as UNKNOWN, not as a merged workflow"

# A directory that cannot be listed is UNKNOWN, never an empty inventory.
locked="$tmp/locked"
mkdir "$locked"
chmod 000 "$locked"
rc=0
out="$(bash "$inventory" --dir "$locked" --repo fixture 2>/dev/null)" || rc=$?
chmod 700 "$locked"
[ "$rc" -eq 2 ] || fail "an unreadable directory must exit 2, got $rc"
grep -q "$(printf '^fixture\tUNKNOWN')" <<<"$out" || fail "an unreadable directory must be reported as UNKNOWN"

# Org mode against a stub gh: a 404 counts as "no workflows" only when the repository root is
# readable; an unreadable repository is UNKNOWN and fails the run.
bin="$tmp/bin"
mkdir "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
# Content reads answer only at the pinned commit s1: an unpinned read returns 404.
case "$2" in
  orgs/fix/repos) printf 'false readable\nfalse nowf\nfalse hidden\nfalse empty\nfalse huge\ntrue retired\n' ;;
  orgs/fix) echo "${EXPECTED-6}" ;;
  orgs/none/repos) printf 'true retired\n' ;;
  orgs/none) echo 1 ;;
  repos/fix/empty/commits/HEAD) echo 'gh: Git Repository is empty. (HTTP 409)' >&2; exit 1 ;;
  repos/fix/hidden/commits/HEAD) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  repos/fix/*/commits/HEAD) echo s1 ;;
  "repos/fix/huge/contents/.github/workflows?ref=s1") echo TRUNCATED ;;
  repos/fix/*/actions/policies) echo 0 ;;
  "repos/fix/readable/contents/.github/workflows?ref=s1") echo ci.yaml ;;
  "repos/fix/readable/contents/.github/workflows/ci.yaml?ref=s1") printf 'on: push\njobs: {}\n' ;;
  *) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/gh"
rc=0
out="$(PATH="$bin:$PATH" bash "$inventory" --org fix 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable repository must make the org inventory exit 2, got $rc"
grep -q "$(printf '^readable\tci.yaml\tpush\tci\t0$')" <<<"$out" || fail "the readable repository's workflow is missing"
grep -q "$(printf '^hidden\tUNKNOWN')" <<<"$out" || fail "a repository hidden behind a 404 must be UNKNOWN"
grep -q '^nowf' <<<"$out" && fail "a repository with a readable root and no workflows must be omitted"
grep -q '^retired' <<<"$out" && fail "an archived repository must not be inventoried"
grep -q '^empty' <<<"$out" && fail "an empty repository has no workflows and must be omitted"
grep -q "$(printf '^huge\tUNKNOWN')" <<<"$out" || fail "a listing at the 1,000-entry cap must be UNKNOWN"

# A token that sees only some repositories lists them successfully; the organisation count exposes it.
for expected in 7 ""; do
  rc=0
  err="$(EXPECTED="$expected" PATH="$bin:$PATH" bash "$inventory" --org fix 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 2 ] || fail "an incomplete listing (expected='$expected') must exit 2, got $rc"
  grep -q 'the token cannot see them all' <<<"$err" || fail "an incomplete listing must say why: $err"
done

# An organisation whose complete listing holds no active repository is a complete, empty inventory.
rc=0
out="$(PATH="$bin:$PATH" bash "$inventory" --org none 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "an organisation with no active repositories must exit 0, got $rc"
[ "$(grep -c . <<<"$out")" -eq 1 ] || fail "an organisation with no active repositories must print only the header"

echo "workflow-execution-inventory test: ok"
