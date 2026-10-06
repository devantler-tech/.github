#!/usr/bin/env bash
# Cleanup self-tests must exercise the production wrapper without deletion authority.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/delete-workflow-runs-readonly.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
production="${3:-$root/.github/workflows/delete-workflow-runs.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$workflow" >"$work/workflow.json"
yq -o=json '.' "$ci" >"$work/ci.json"
yq -o=json '.' "$production" >"$work/production.json"
go run "$root/.github/tests/cleanup-credentials.go" "$work"
bash "$root/.github/scripts/generate-cleanup-readonly.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/workflow.json" >"$work/checked.json"
cmp "$work/generated.json" "$work/checked.json" || {
  echo 'FAIL: cleanup projection differs from production; regenerate it' >&2
  exit 1
}
echo 'PASS: complete cleanup projection matches current production source'
go test -race "$root/.github/scripts/delete-workflow-runs/main.go" "$root/.github/scripts/delete-workflow-runs/main_test.go" -count=1
