#!/usr/bin/env bash
# Invalid or empty fixtures must fail before Docker can execute anything.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$root/.github/tests/todo-scanner/cases.json" >"$work/cases.json"
  for mode in --check-fixtures --cases; do
    if bash "$root/.github/tests/test-todo-scanner.sh" "$mode" "$work/cases.json" >"$work/result" 2>&1; then
      echo "FAIL: $name accepted by $mode" >&2; exit 1
    fi
    grep -qF 'Invalid scanner scenarios' "$work/result" || { cat "$work/result"; exit 1; }
  done
done <<'CASES'
empty cases	[]
no source files	.[0].Files={}
unsafe file path	.[0].Files={"../escaped.sh": {Before:"",After:""}}
missing operations	.[0] |= del(.Operations)
missing results	.[0] |= del(.Output)
duplicate scenario	. + [.[0]]
non-boolean exit expectation	.[0].WantFailure="false"
non-array forbidden results	.[0].ForbiddenOutput="Issue created"
empty forbidden result	.[0].ForbiddenOutput=[""]
non-array initial reads	.[0].InitialReads={}
empty initial reads	.[0].InitialReads=[]
invalid initial read status	.[0].InitialReads=[{Method:"GET",Path:"/repos/offline/fixture/issues",Status:0,Response:"[]"}]
non-string initial read response	.[0].InitialReads=[{Method:"GET",Path:"/repos/offline/fixture/issues",Status:503,Response:{message:"Failure"}}]
CASES
bash "$root/.github/tests/test-todo-scanner.sh" --check-fixtures "$root/.github/tests/todo-scanner/cases.json"
echo 'PASS: 13 invalid scanner fixtures are rejected in validation and execution modes'
