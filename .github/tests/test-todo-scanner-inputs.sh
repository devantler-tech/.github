#!/usr/bin/env bash
# Invalid or empty fixtures must fail before Docker can execute anything.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$root/.github/tests/todo-scanner/cases.json" >"$work/cases.json"
  if bash "$root/.github/tests/test-todo-scanner.sh" --check-fixtures "$work/cases.json" >"$work/result" 2>&1; then
    echo "FAIL: $name accepted" >&2; exit 1
  fi
  grep -qF 'Invalid scanner scenarios' "$work/result" || { cat "$work/result"; exit 1; }
done <<'CASES'
empty cases	[]
no source files	.[0].Files={}
unsafe file path	.[0].Files={"../escaped.sh": {Before:"",After:""}}
missing operations	.[0] |= del(.Operations)
missing results	.[0] |= del(.Output)
duplicate scenario	. + [.[0]]
CASES
bash "$root/.github/tests/test-todo-scanner.sh" --check-fixtures "$root/.github/tests/todo-scanner/cases.json"
echo 'PASS: 6 invalid scanner scenario fixtures are rejected'
