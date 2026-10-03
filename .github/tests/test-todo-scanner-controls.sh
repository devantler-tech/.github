#!/usr/bin/env bash
# Negative controls execute the unchanged pinned scanner, with literal API expectations.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jq '[.[0]]' "$root/.github/tests/todo-scanner/cases.json" >"$work/healthy.json"

healthy() {
  bash "$root/.github/tests/test-todo-scanner.sh" --cases "$work/healthy.json"
}
reject() {
  local cases="$1" diagnostic="$2"
  if bash "$root/.github/tests/test-todo-scanner.sh" --cases "$cases" >"$work/result" 2>&1; then
    echo "FAIL: native scanner control accepted $cases" >&2
    exit 1
  fi
  # Pull, build, usage and fixture errors must never count as the expected regression.
  grep -qF "$diagnostic" "$work/result" || { cat "$work/result"; exit 1; }
}

healthy
# Keep the required search/write operations and successful result expectations intact.
# Removing the recognized markers must therefore leave required API requests unconsumed.
jq '.[0].Files |= with_entries(.value.After |= gsub("TODO|ToDo"; "NOTE"))' \
  "$work/healthy.json" >"$work/discovery.json"
reject "$work/discovery.json" 'missing requests'
healthy
# The expected payload is a literal fixture, never learned from the scanner response.
jq '.[0].Operations[1].Body |= (fromjson | .title = "Incorrect fixture title" | tojson)' \
  "$work/healthy.json" >"$work/payload.json"
reject "$work/payload.json" 'issue payload differs'
healthy
echo 'PASS: native discovery and payload regressions fail for their own reasons'
