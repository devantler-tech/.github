#!/usr/bin/env bash
# Exercise the real deadline guard; an added unbounded runner must never pass.
set -euo pipefail

guard=${1:-.github/tests/test-ci-runner-timeouts.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/good.yaml" <<'YAML'
jobs:
  run:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - run: echo fixture
  call:
    uses: ./.github/workflows/example.yaml
YAML

bash "$guard" "$tmp/good.yaml" >"$tmp/out" 2>&1
cases=0
reject() {
  local name=$1 file=$2 expected=${3:-'invalid direct job deadline or reusable call'}
  if bash "$guard" "$file" >"$tmp/out" 2>&1; then
    echo "FAIL: deadline guard accepted $name" >&2
    exit 1
  fi
  if ! grep -qF "$expected" "$tmp/out"; then
    echo "FAIL: $name was refused without its expected diagnostic" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  cases=$((cases + 1))
}

# shellcheck disable=SC2016 # A GitHub expression must remain literal fixture data.
for value in 0 -1 16 1.5 '"5"' true null '"${{ 5 }}"'; do
  TIMEOUT_JSON="$value" yq '.jobs.run.timeout-minutes = (strenv(TIMEOUT_JSON) | from_json)' \
    "$tmp/good.yaml" >"$tmp/bad.yaml"
  reject "invalid limit $value" "$tmp/bad.yaml"
done
for value in 1 15; do
  TIMEOUT_JSON="$value" yq '.jobs.run.timeout-minutes = (strenv(TIMEOUT_JSON) | from_json)' \
    "$tmp/good.yaml" >"$tmp/boundary.yaml"
  bash "$guard" "$tmp/boundary.yaml" >"$tmp/out" 2>&1
done
yq 'del(.jobs.run.timeout-minutes) | .jobs.run.steps[0].timeout-minutes = 5' \
  "$tmp/good.yaml" >"$tmp/bad.yaml"
reject 'step-only deadline without a runner deadline' "$tmp/bad.yaml"
yq '.jobs.call.timeout-minutes = 5' "$tmp/good.yaml" >"$tmp/bad.yaml"
reject 'unsupported reusable-call deadline' "$tmp/bad.yaml"
yq '.jobs.call.steps = [{"run": "true"}]' "$tmp/good.yaml" >"$tmp/bad.yaml"
reject 'ambiguous call with inline steps' "$tmp/bad.yaml"
yq '.jobs.call.uses = null' "$tmp/good.yaml" >"$tmp/bad.yaml"
reject 'null reusable call' "$tmp/bad.yaml"
printf 'jobs: {}\n' >"$tmp/bad.yaml"
reject 'empty job inventory' "$tmp/bad.yaml" 'expected a nonempty job mapping'
printf 'jobs:\n  run: null\n' >"$tmp/bad.yaml"
reject 'non-object job' "$tmp/bad.yaml" 'expected a nonempty job mapping'
printf 'jobs: [\n' >"$tmp/bad.yaml"
reject 'malformed workflow' "$tmp/bad.yaml" 'cannot parse workflow jobs'
reject 'missing workflow' "$tmp/missing.yaml" 'expected one existing workflow'

# Use the real shipping graph for the regression, not only the small fixtures.
bash "$guard" .github/workflows/ci.yaml >"$tmp/out" 2>&1
yq 'del(.jobs.test-run-dotnet-tests-workflow.timeout-minutes)' \
  .github/workflows/ci.yaml >"$tmp/bad.yaml"
reject 'native .NET runner regaining the six-hour default' "$tmp/bad.yaml"
yq '.jobs.new-unbounded = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}' \
  .github/workflows/ci.yaml >"$tmp/bad.yaml"
reject 'new unbounded runner' "$tmp/bad.yaml"

echo "PASS: $cases deadline refusal controls and valid literal/callee-owned boundaries"
