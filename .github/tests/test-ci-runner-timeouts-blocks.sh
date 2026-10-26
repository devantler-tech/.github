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

# Shared workflows own their runner limits, including the existing scanner's
# deliberate 60-minute ceiling. The direct CI job ceiling must stay at fifteen.
yq '.on.workflow_call = null | .jobs.run.timeout-minutes = 60' \
  "$tmp/good.yaml" >"$tmp/callee.yaml"
bash "$guard" --callee "$tmp/callee.yaml" >"$tmp/out" 2>&1
reject 'a callee budget used on a direct CI runner' "$tmp/callee.yaml"

reject_callee() {
  local name=$1 file=$2
  if bash "$guard" --callee "$file" >"$tmp/out" 2>&1; then
    echo "FAIL: callee deadline guard accepted $name" >&2
    exit 1
  fi
  grep -qF 'invalid direct job deadline or reusable call' "$tmp/out" || {
    cat "$tmp/out" >&2
    exit 1
  }
  cases=$((cases + 1))
}
for value in 0 61 1.5 '"10"' null; do
  TIMEOUT_JSON="$value" yq '.jobs.run.timeout-minutes = (strenv(TIMEOUT_JSON) | from_json)' \
    "$tmp/callee.yaml" >"$tmp/bad-callee.yaml"
  reject_callee "invalid shared limit $value" "$tmp/bad-callee.yaml"
done
yq 'del(.jobs.run.timeout-minutes)' "$tmp/callee.yaml" >"$tmp/bad-callee.yaml"
reject_callee 'unbounded shared runner' "$tmp/bad-callee.yaml"
yq '.jobs.call.timeout-minutes = 10' "$tmp/callee.yaml" >"$tmp/bad-callee.yaml"
reject_callee 'unsupported caller-level limit in a shared workflow' "$tmp/bad-callee.yaml"

mkdir "$tmp/callees" "$tmp/empty"
cp "$tmp/callee.yaml" "$tmp/callees/good.yaml"
# A repo-owned workflow is outside this guard's callable-only scope.
printf 'on: push\njobs: {owner: {runs-on: ubuntu-latest}}\n' >"$tmp/callees/owner.yml"
bash "$guard" --callees "$tmp/callees" >"$tmp/out" 2>&1
for trigger in '"workflow_call"' '["push", "workflow_call"]'; do
  TRIGGER_JSON="$trigger" yq '.on = (strenv(TRIGGER_JSON) | from_json)' \
    "$tmp/callee.yaml" >"$tmp/callees/good.yaml"
  bash "$guard" --callees "$tmp/callees" >"$tmp/out" 2>&1
done
cp "$tmp/callee.yaml" "$tmp/callees/good.yaml"
printf 'on: null\njobs: {}\n' >"$tmp/callees/unknown.yaml"
if bash "$guard" --callees "$tmp/callees" >"$tmp/out" 2>&1; then
  echo 'FAIL: an unclassified workflow trigger was ignored' >&2
  exit 1
fi
grep -qF 'cannot classify workflow triggers' "$tmp/out"
rm "$tmp/callees/unknown.yaml"
if bash "$guard" --callees "$tmp/empty" >"$tmp/out" 2>&1; then
  echo 'FAIL: empty callable inventory accepted' >&2
  exit 1
fi
grep -qF 'no callable workflows examined' "$tmp/out"
cp "$tmp/bad-callee.yaml" "$tmp/callees/new.yaml"
if bash "$guard" --callees "$tmp/callees" >"$tmp/out" 2>&1; then
  echo 'FAIL: a newly added unsafe callable workflow was ignored' >&2
  exit 1
fi
grep -qF 'invalid direct job deadline or reusable call' "$tmp/out"
rm "$tmp/callees/new.yaml"
ln -s "$tmp/callee.yaml" "$tmp/callees/linked.yaml"
if bash "$guard" --callees "$tmp/callees" >"$tmp/out" 2>&1; then
  echo 'FAIL: symlinked callable metadata was followed' >&2
  exit 1
fi
grep -qF 'expected a regular workflow' "$tmp/out"

callee_invocation_present() {
  yq -o=json '.' "$1" | jq -e --arg run \
    'bash .github/tests/test-ci-runner-timeouts.sh --callees .github/workflows' '
      [.jobs["lint-ci-coverage-parity"].steps[]
       | select(.run == $run and .shell == "bash" and (has("if") | not)
         and ((has("continue-on-error") | not) or .["continue-on-error"] == false))]
      | length == 1' >/dev/null
}
callee_invocation_present .github/workflows/ci.yaml || {
  echo 'FAIL: required catalogue guard lost its dedicated callee inventory step' >&2
  exit 1
}
SCAN_RUN='bash .github/tests/test-ci-runner-timeouts.sh --callees .github/workflows' \
  yq '.jobs.lint-ci-coverage-parity.steps |= map(select(.run != strenv(SCAN_RUN)))' \
  .github/workflows/ci.yaml >"$tmp/missing-scan.yaml"
if callee_invocation_present "$tmp/missing-scan.yaml"; then
  echo 'FAIL: removing the actual callee inventory invocation was not detected' >&2
  exit 1
fi

echo "PASS: $cases deadline refusal controls and valid literal/callee-owned boundaries"
