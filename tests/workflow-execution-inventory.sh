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

echo "workflow-execution-inventory test: ok"
