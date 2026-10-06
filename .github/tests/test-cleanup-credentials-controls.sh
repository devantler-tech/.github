#!/usr/bin/env bash
# Independently break deletion authority, reachability and wrapper semantics.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/delete-workflow-runs-readonly.yaml" >"$work/workflow.json"
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/ci.json"
yq -o=json '.' "$root/.github/workflows/delete-workflow-runs.yaml" >"$work/production.json"
count=0
while IFS=$'\t' read -r source mutation diagnostic; do
  input="$source"
  [[ "$source" != projection ]] || input=production
  jq "$mutation" "$work/$input.json" >"$work/mutated.json"
  workflow="$work/workflow.json"
  ci="$work/ci.json"
  production="$work/production.json"
  if [[ "$source" == workflow ]]; then
    workflow="$work/mutated.json"
  elif [[ "$source" == ci ]]; then
    ci="$work/mutated.json"
  else
    production="$work/mutated.json"
    workflow="$work/projected.yaml"
    bash "$root/.github/scripts/generate-cleanup-readonly.sh" "$production" "$workflow"
  fi
  if bash "$root/.github/tests/test-cleanup-credentials.sh" "$workflow" "$ci" "$production" >"$work/result" 2>&1; then
    echo "FAIL: cleanup regression accepted: $mutation" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
ci	.jobs["test-delete-workflow-runs-all"].permissions.actions="write"	cleanup caller has deletion authority
ci	.jobs["test-delete-workflow-runs-specific"].permissions.contents="write"	cleanup caller has deletion authority
ci	.jobs["test-delete-workflow-runs-minimal"].secrets="inherit"	cleanup caller forwards secrets
ci	.jobs["test-delete-workflow-runs-all"].uses="./.github/workflows/delete-workflow-runs.yaml"	cleanup caller bypasses read-only entrypoint
ci	del(.jobs["test-delete-workflow-runs-specific"])	cleanup scenario missing
ci	.jobs["test-delete-workflow-runs-all"].if="false"	cleanup admission changed
ci	.jobs["test-delete-workflow-runs-minimal"]["continue-on-error"]=true	cleanup failure ignored
ci	.jobs["test-delete-workflow-runs-minimal"].with={"dry-run":true}	minimal scenario must exercise declared defaults
ci	.jobs["test-delete-workflow-runs-specific"].with["dry-run"]=false	specific scenario must explicitly dry-run
ci	.jobs["test-delete-workflow-runs-all"].with.repository="${{ secrets.APP_PRIVATE_KEY }}"	cleanup forwards a mutation credential
ci	.jobs["ci-required-checks"].needs -= ["test-delete-workflow-runs-all"]	cleanup caller omitted from required needs
ci	.jobs["ci-required-checks"].steps[0].env.JOB_RESULTS |= sub("\\$\\{\\{ needs.test-delete-workflow-runs-specific.result \\}\\}"; "")	cleanup caller omitted from required summary
ci	.jobs["ci-required-checks"].needs -= ["test-delete-workflow-runs-minimal"] | .jobs["ci-required-checks"].steps[0].env.JOB_RESULTS |= sub("\\$\\{\\{ needs.test-delete-workflow-runs-minimal.result \\}\\}"; "")	cleanup caller omitted from required needs
workflow	.jobs["delete-runs"].permissions.actions="write"	cleanup callee has deletion authority
workflow	.jobs["delete-runs"].steps[3].run="echo skipped"	cleanup projection changed production steps
workflow	.jobs["delete-runs"].if="false"	cleanup execution disabled
workflow	.jobs["delete-runs"]["continue-on-error"]=true	cleanup execution ignores failure
workflow	.permissions.actions="write"	workflow grants ambient credentials
projection	.jobs["delete-runs"].steps[1].env.TOKEN="${{\n toJson(\n Secrets\n )\n}}"	cleanup forwards a mutation credential
projection	.on.workflow_call.inputs["dry-run"].default=false	cleanup input behavior changed
projection	.jobs["delete-runs"].steps[3].env.INPUT_DRY_RUN="${{ inputs.repository }}"	cleanup input behavior changed
projection	.jobs["delete-runs"].steps[3].env.INPUT_RETAIN_DAYS="${{ inputs.minimum-runs }}"	cleanup input behavior changed
projection	.jobs["delete-runs"].steps[3].env.INPUT_REPOSITORY="${{ inputs.repository }}"	cleanup input behavior changed
projection	.jobs["delete-runs"].steps[3].env.INPUT_DELETE_WORKFLOW_BY_STATE_PATTERN="${{ inputs.delete-run-by-conclusion-pattern }}"	cleanup input behavior changed
projection	.jobs["delete-runs"].steps[3].env.CLEANUP_TOKEN="${{ secrets.APP_TOKEN }}"	cleanup forwards a mutation credential
projection	.jobs["delete-runs"].steps[3].if=false	production cleanup action disabled
projection	.jobs["delete-runs"].steps[1].with.ref="main"	cleanup source is not this workflow's commit
projection	.jobs["delete-runs"].steps[1].with["persist-credentials"]=true	cleanup source is not this workflow's commit
projection	.jobs["delete-runs"].steps[3].run="echo skipped"	cleanup driver bypassed
CASES
echo "PASS: $count independent cleanup credential, execution and input regressions rejected"
