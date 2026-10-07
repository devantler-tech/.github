#!/usr/bin/env bash
# Execute the actual composite's inline script against a synthetic Kubernetes API.
set -euo pipefail
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$test_dir/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
GO111MODULE=off go build -o "$scratch/contract" "$test_dir/diagnose-flux/contract.go"
"$scratch/contract" "${DIAGNOSE_ACTION:-$repo/actions/diagnose-flux/action.yaml}" "${1:-all}"
if [[ "${1:-all}" == all ]]; then
  "$scratch/contract" "${DIAGNOSE_ACTION:-$repo/actions/diagnose-flux/action.yaml}" mutants
fi
