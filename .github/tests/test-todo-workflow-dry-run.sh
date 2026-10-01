#!/usr/bin/env bash
# Protect the executed reusable-workflow smoke separately from scanner behavior.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "${1:-$root/.github/workflows/scan-for-todo-comments.yaml}" >"$work/workflow.json"
yq -o=json '.' "${2:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"
jq -n --slurpfile workflow "$work/workflow.json" --slurpfile ci "$work/ci.json" \
  '{workflow:$workflow[0],ci:$ci[0]}' >"$work/bundle.json"

guard() {
  jq -e '
    def command: .run // "" | gsub("^\\s+|\\s+$";"");
    def runnable:
      .if == null and ( .["continue-on-error"] // false ) == false and
      (.shell == null or .shell == "bash") and
      (.["working-directory"] == null or .["working-directory"] == ".");
    def default_run:
      (.shell == null or .shell == "bash") and
      (.["working-directory"] == null or .["working-directory"] == ".");
    .workflow as $wf | .ci as $ci | $wf.jobs["dry-run"] as $job |
    if $wf.on.workflow_call.inputs["dry-run"].default != false or
      $wf.on.workflow_call.secrets.APP_PRIVATE_KEY.required != false
    then error("dry-run stays default-off and its unused secret must be optional")
    elif $wf.permissions != {} or $wf.jobs.todos.if != "${{ !inputs.dry-run }}" or
      $wf.jobs.todos.permissions != {contents:"read",issues:"write"} or
      ([$wf.jobs.todos.steps[] | select(.uses == "./.devantler-tech-actions/actions/create-issues-from-todos") | .with] !=
        [{"client-id":"${{ vars.APP_CLIENT_ID }}","app-private-key":"${{ secrets.APP_PRIVATE_KEY }}",
          project:"organization/devantler-tech/5",ignore:"${{ inputs.ignore }}"}])
    then error("production gate, permissions and project authentication must remain intact")
    elif $job == null or $job.if != "${{ inputs.dry-run }}" or
      ($job["continue-on-error"] // false) != false or $job.needs != null
    then error("dry-run must execute independently and propagate failures")
    elif $job.permissions != {contents:"read"}
    then error("executed dry-run token must have only contents-read permission")
    elif ([$wf.env // {},$job] | tostring | test("\\bsecrets\\b|app-private-key|client-id|\\bGH_TOKEN\\b|\\bGITHUB_TOKEN\\b";"i"))
    then error("dry-run must not forward production credentials")
    elif ([$job.steps[] | select((.uses // ""|startswith("actions/checkout@")))] |
      length != 3 or any(.with["persist-credentials"] != false))
    then error("all dry-run checkouts must disable persisted credentials")
    elif ([$job.steps[]|select(.with.path == ".devantler-tech-actions")] |
      length != 2 or any(.with.repository != "${{ job.workflow_repository }}" or
        .with.ref != "${{ job.workflow_sha }}"))
    then error("action and fixture must resolve at this workflow commit")
    elif ([$job.steps[]|select(.uses == "./.devantler-tech-actions/actions/create-issues-from-todos")] |
      length != 1 or any((runnable|not) or
        .with != {ignore:"${{ inputs.ignore }}","optional-project-auth":"true"}))
    then error("actual offline action must execute with unchanged ignore and no project")
    elif (["prepare","verify-once"] | all(. as $mode |
      [$job.steps[]|select(command == "bash .devantler-tech-actions/.github/tests/todo-action-smoke.sh "+$mode)] |
      length == 1 and all(runnable))) | not
    then error("fixture preparation and exact-one verification must execute")
    elif ($wf.defaults.run|default_run|not) or ($job.defaults.run|default_run|not)
    then error("dry-run cannot replace the shell or working directory")
    elif ([$job.steps[]|select(command == "bash .devantler-tech-actions/.github/tests/todo-action-smoke.sh prepare")|.env] !=
      [{TODO_EXPECTED_TOKEN:"${{ github.token }}",TODO_EXPECTED_BEFORE:"${{ github.event.before || github.base_ref }}",
        TODO_EXPECTED_COMMITS:"${{ toJSON(github.event.commits) }}",
        TODO_EXPECTED_DIFF:"${{ github.event.pull_request.diff_url }}",TODO_EXPECTED_IGNORE:"${{ inputs.ignore }}"}])
    then error("fixture expectations must bind independently to caller inputs")
    elif ($job.steps|to_entries|map(select(.value.with.path == ".devantler-tech-actions"))|.[0].key) as $checkout |
      ($job.steps|to_entries|map(select((.value|command)|endswith("todo-action-smoke.sh prepare")))|.[0].key) as $prepare |
      ($job.steps|to_entries|map(select(.value.uses == "./.devantler-tech-actions/actions/create-issues-from-todos"))|.[0].key) as $action |
      ($job.steps|to_entries|map(select(.value.with.path == ".devantler-tech-actions"))|.[1]) as $restore |
      ($job.steps|to_entries|map(select((.value|command)|endswith("todo-action-smoke.sh verify-once")))|.[0].key) as $verify |
      ($checkout < $prepare and $prepare < $action and $action < $restore.key and
        $restore.key < $verify and $restore.value.if == "${{ always() }}") | not
    then error("restore the cleaned action checkout before verification and post-cleanup")
    elif (["test-scan-for-todo-comments","test-scan-for-todo-comments-ignore"] | all(. as $name |
      $ci.jobs[$name].uses == "./.github/workflows/scan-for-todo-comments.yaml" and
      $ci.jobs[$name].with["dry-run"] == true and $ci.jobs[$name].secrets == null and
      ($ci.jobs["ci-required-checks"].needs | index($name)) != null and
      any($ci.jobs["ci-required-checks"].steps[];
        (.env.JOB_RESULTS // "" | contains("needs."+$name+".result")) and
        (.run // "" | contains("$JOB_RESULTS"))))) | not
    then error("both secret-free workflow calls must gate required CI")
    elif (["test-todo-workflow-dry-run.sh","test-todo-workflow-fixture.sh"] | all(. as $script |
      [$ci.jobs["test-create-issues-from-todos"].steps[] |
        select(command == "bash .github/tests/"+$script)] | length == 1 and all(runnable))) | not
    then error("dry-run regressions must execute in catalogue CI")
    else true end' "$1"
}
guard "$work/bundle.json" >/dev/null
[[ "${3:-}" != --guard-only ]] || exit 0
count=0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/bundle.json" >"$work/mutated.json"
  if guard "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
required unused secret	.workflow.on.workflow_call.secrets.APP_PRIVATE_KEY.required=true	unused secret
default live activation	.workflow.on.workflow_call.inputs["dry-run"].default=true	default-off
production gate bypass	.workflow.jobs.todos.if=null	production gate
production write scope lost	.workflow.jobs.todos.permissions.issues="read"	production gate
production App binding lost	.workflow.jobs.todos.steps |= map(if .with.project then del(.with["app-private-key"]) else . end)	production gate
missing dry-run	.workflow.jobs |= del(.["dry-run"])	execute independently
skipped dry-run	.workflow.jobs["dry-run"].if="false"	execute independently
ignored job failure	.workflow.jobs["dry-run"]["continue-on-error"]=true	execute independently
blocked on skipped production	.workflow.jobs["dry-run"].needs="todos"	execute independently
write token	.workflow.jobs["dry-run"].permissions.issues="write"	only contents-read
missing token restriction	.workflow.jobs["dry-run"].permissions=null	only contents-read
job App key	.workflow.jobs["dry-run"].env.EXTRA="${{ secrets.APP_PRIVATE_KEY }}"	production credentials
workflow credential	.workflow.env.GH_TOKEN="live-token"	production credentials
persisted checkout	.workflow.jobs["dry-run"].steps |= map(if .with["persist-credentials"] == false then .with["persist-credentials"]=true else . end)	persisted credentials
mutable fixture ref	.workflow.jobs["dry-run"].steps |= map(if .with.path then .with.ref="main" else . end)	workflow commit
missing action	.workflow.jobs["dry-run"].steps |= map(select(.uses != "./.devantler-tech-actions/actions/create-issues-from-todos"))	actual offline action
skipped action	.workflow.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then .if="false" else . end)	actual offline action
ignored action failure	.workflow.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then .["continue-on-error"]=true else . end)	actual offline action
lost ignore forwarding	.workflow.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then .with.ignore="" else . end)	actual offline action
lost optional auth	.workflow.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then del(.with["optional-project-auth"]) else . end)	actual offline action
live project	.workflow.jobs["dry-run"].steps |= map(if .uses == "./.devantler-tech-actions/actions/create-issues-from-todos" then .with.project="organization/devantler-tech/5" else . end)	actual offline action
skipped prepare	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" prepare")) then .if="false" else . end)	exact-one verification
printed verdict	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" verify-once")) then .run="echo verified" else . end)	exact-one verification
ignored verifier failure	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" verify-once")) then .["continue-on-error"]=true else . end)	exact-one verification
custom verifier shell	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" verify-once")) then .shell="echo {0}" else . end)	exact-one verification
vacuous verifier	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" verify-once")) then .run |= sub("verify-once$";"verify") else . end)	exact-one verification
job custom shell	.workflow.jobs["dry-run"].defaults.run.shell="true {0}"	replace the shell
workflow shadow directory	.workflow.defaults.run["working-directory"]="shadow"	working directory
broken independent expectation	.workflow.jobs["dry-run"].steps |= map(if (.run // "" | endswith(" prepare")) then .env.TODO_EXPECTED_IGNORE="" else . end)	independently to caller
missing cleanup restore	.workflow.jobs["dry-run"].steps |= map(if .with.path and .if then .if=null else . end)	post-cleanup
verify before action	.workflow.jobs["dry-run"].steps |= ([.[]|select(.run // ""|endswith(" verify-once"))]+[.[]|select((.run // ""|endswith(" verify-once"))|not)])	post-cleanup
default caller secret	.ci.jobs["test-scan-for-todo-comments"].secrets.APP_PRIVATE_KEY="${{ secrets.APP_PRIVATE_KEY }}"	secret-free workflow calls
ignore caller inherit	.ci.jobs["test-scan-for-todo-comments-ignore"].secrets="inherit"	secret-free workflow calls
caller live mode	.ci.jobs["test-scan-for-todo-comments"].with["dry-run"]=false	secret-free workflow calls
missing required dependency	.ci.jobs["ci-required-checks"].needs |= map(select(. != "test-scan-for-todo-comments-ignore"))	secret-free workflow calls
missing required verdict	.ci.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-scan-for-todo-comments.result";"needs.other.result") else . end)	secret-free workflow calls
skipped regression	.ci.jobs["test-create-issues-from-todos"].steps |= map(if .run == "bash .github/tests/test-todo-workflow-dry-run.sh" then .if="false" else . end)	regressions must execute
missing fixture regression	.ci.jobs["test-create-issues-from-todos"].steps |= map(select(.run != "bash .github/tests/test-todo-workflow-fixture.sh"))	regressions must execute
CASES
echo "PASS: $count mutations preserve secret-free reusable dry-run execution"
