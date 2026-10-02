#!/usr/bin/env bash
# Mutations must fail even when a changed production workflow is regenerated.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/scan-for-todo-comments-readonly.yaml" >"$work/workflow.json"
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/ci.json"
yq -o=json '.' "$root/.github/workflows/scan-for-todo-comments.yaml" >"$work/production.json"
check="$root/.github/tests/test-todo-workflow-readonly.sh"
bash "$check" "$work/workflow.json" "$work/ci.json" "$work/production.json"
count=0
while IFS=$'\t' read -r scope mutation diagnostic; do
  workflow="$work/workflow.json"
  ci="$work/ci.json"
  production="$work/production.json"
  jq "$mutation" "$work/$scope.json" >"$work/mutated.json"
  case "$scope" in
    workflow) workflow="$work/mutated.json" ;;
    ci) ci="$work/mutated.json" ;;
    production)
      production="$work/mutated.json"
      workflow="$work/regenerated.yaml"
      bash "$root/.github/scripts/generate-todo-readonly.sh" "$production" "$workflow"
      ;;
  esac
  if bash "$check" "$workflow" "$ci" "$production" >"$work/result" 2>&1; then
    echo "FAIL: TODO regression accepted: $mutation" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
ci	.jobs["test-scan-for-todo-comments"].permissions.issues="write"	callers must grant only contents-read
ci	.jobs["test-scan-for-todo-comments-ignore"].permissions.contents="write"	callers must grant only contents-read
ci	.jobs["test-scan-for-todo-comments"].uses="./.github/workflows/scan-for-todo-comments.yaml"	read-only entrypoint
ci	.jobs.extra = .jobs["test-scan-for-todo-comments"]	unexpected TODO workflow caller
ci	.jobs["test-scan-for-todo-comments-ignore"].secrets="inherit"	secret-free read-only entrypoint
ci	.jobs["test-scan-for-todo-comments"].env.GH_TOKEN="${{ secrets.APP_PRIVATE_KEY }}"	secret-free read-only entrypoint
ci	.jobs["test-scan-for-todo-comments"].with["dry-run"]=false	read-only entrypoint
ci	.jobs["test-scan-for-todo-comments"].with.ignore="^third_party/"	preserve inputs
ci	.jobs["test-scan-for-todo-comments-ignore"].with.ignore=""	preserve inputs
ci	.jobs["test-scan-for-todo-comments"].if="false"	secret-free workflow calls
ci	.jobs["test-scan-for-todo-comments-ignore"]["continue-on-error"]=true	secret-free workflow calls
ci	.jobs["ci-required-checks"].needs -= ["test-scan-for-todo-comments"]	secret-free workflow calls
ci	.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-scan-for-todo-comments-ignore.result";"needs.other.result") else . end)	secret-free workflow calls
workflow	.jobs.todos.permissions.issues="write"	every job read-only
workflow	.permissions.contents="write"	changed production behavior
workflow	del(.jobs.todos)	changed production behavior
workflow	.jobs["dry-run"].steps |= map(select((.run // ""|endswith(" verify-once"))|not))	changed production behavior
workflow	.on.workflow_call.inputs.ignore.default="lost-source-input"	changed production behavior
production	.jobs["dry-run"].permissions.issues="write"	every job read-only
production	.jobs.extra={"runs-on":"ubuntu-latest",permissions:{contents:"write"},steps:[]}	every job read-only
production	.jobs["dry-run"].env.TOKEN="${{ secrets.APP_PRIVATE_KEY }}"	production credentials
production	.jobs["dry-run"].steps |= map(if (.run // ""|endswith(" verify-once")) then .if="false" else . end)	exact-one verification
production	.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then .with.ignore="" else . end)	actual offline action
production	.jobs.todos.if="${{ inputs.dry-run }}"	production gate
CASES
# A harmless production step must survive generation without editing the test.
jq '.jobs["dry-run"].steps += [{name:"source parity sentinel",run:"true"}]' "$work/production.json" >"$work/with-step.json"
bash "$root/.github/scripts/generate-todo-readonly.sh" "$work/with-step.json" "$work/with-step.yaml"
bash "$check" "$work/with-step.yaml" "$work/ci.json" "$work/with-step.json"
# Omitting that new source step from the projection must fail, independent of the generator.
if bash "$check" "$work/workflow.json" "$work/ci.json" "$work/with-step.json" >"$work/result" 2>&1; then
  echo 'FAIL: source drift accepted' >&2
  exit 1
fi
grep -qF 'changed production behavior' "$work/result"
echo "PASS: $count independent TODO permission, execution and source regressions rejected"
