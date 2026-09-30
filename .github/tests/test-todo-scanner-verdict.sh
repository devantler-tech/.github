#!/usr/bin/env bash
# A successful command is insufficient unless the real fixture finished this case.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for result in '' 'PASS: real pinned scanner — another case (9 requests)' 'PASS: real pinned scanner — fixture case (0 requests)' 'printed PASS: real pinned scanner — fixture case (9 requests)'; do
  printf '%s\n' "$result" >"$work/result"
  if bash "$root/.github/tests/todo-scanner-verdict.sh" "$work/result" 'fixture case' 9; then
    echo 'FAIL: skipped or incomplete scanner accepted' >&2; exit 1
  fi
done
printf '%s\n' 'PASS: real pinned scanner — fixture case (9 requests)' >"$work/result"
bash "$root/.github/tests/todo-scanner-verdict.sh" "$work/result" 'fixture case' 9
echo 'PASS: only the completed current scanner scenario is accepted'
