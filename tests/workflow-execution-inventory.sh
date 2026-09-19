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
printf 'on: push\njobs: {}\n' >"$wf/notes.txt"

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
expect pages.yaml push,workflow_dispatch manual-entry,release
expect sync.yaml repository_dispatch manual-entry
expect shared.yaml workflow_call reusable
expect nightly.yaml schedule scheduled
expect cd.yaml push release

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
case "$2" in
  orgs/fix/repos) printf 'false readable\nfalse nowf\nfalse hidden\ntrue retired\n' ;;
  orgs/fix) echo "${EXPECTED-4}" ;;
  repos/fix/*/actions/policies) echo 0 ;;
  repos/fix/readable/contents/.github/workflows) echo ci.yaml ;;
  repos/fix/readable/contents/.github/workflows/ci.yaml) printf 'on: push\njobs: {}\n' ;;
  repos/fix/nowf/contents/) echo 3 ;;
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

# A token that sees only some repositories lists them successfully; the organisation count exposes it.
for expected in 5 ""; do
  rc=0
  err="$(EXPECTED="$expected" PATH="$bin:$PATH" bash "$inventory" --org fix 2>&1 >/dev/null)" || rc=$?
  [ "$rc" -eq 2 ] || fail "an incomplete listing (expected='$expected') must exit 2, got $rc"
  grep -q 'the token cannot see them all' <<<"$err" || fail "an incomplete listing must say why: $err"
done

echo "workflow-execution-inventory test: ok"
