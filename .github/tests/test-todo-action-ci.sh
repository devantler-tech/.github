#!/usr/bin/env bash
# Keep the action smoke offline; the separate reusable workflow coverage belongs to #334.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "${1:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"
condition="\${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"

# Reject unsafe credentials, skipped fixtures and missing required-result propagation.
guard() {
  jq -e --arg condition "$condition" '
    def action_path:
      (split("@")[0] // "") | split("/") | reduce .[] as $part ([];
        if $part == "" or $part == "." then . elif $part == ".." then .[0:-1]
        else .+[$part] end) | last == "create-issues-from-todos";
    def bash_shell: . == null or . == "bash";
    def root_directory: . == null or . == "." or . == "./" or . == "${{ github.workspace }}";
    def command: .run // "" | gsub("^\\s+|\\s+$";"");
    . as $ci | .jobs["test-create-issues-from-todos"] as $job |
    if ($job|type) != "object" then error("offline action job is missing")
    elif $job.permissions != {contents:"read"} then error("only contents-read permission is allowed")
    elif ([.env // {}, $job] | tostring | test("\\bsecrets\\b|app-private-key|GH_TOKEN|GITHUB_TOKEN";"i"))
    then error("action smoke must not forward credentials")
    elif $job.if != $condition or ($job["continue-on-error"] // false) != false
    then error("action smoke must preserve its scheduling and failure boundary")
    elif ([$job.steps[]|select((.uses // "")|startswith("actions/checkout@"))] |
      length == 0 or any(.with["persist-credentials"] != false))
    then error("checkout must not persist credentials")
    elif ([.jobs|to_entries[]|.key as $name|.value.steps[]?|
      select((.uses // "")|action_path)|select($name != "test-create-issues-from-todos" or
        ((.with // {})|keys) != ["ignore"])] | length > 0)
    then error("live to-do action invocation in catalogue CI")
    elif ([$job.steps[]|select(.uses == "./actions/create-issues-from-todos")] |
      length != 1 or any(.if != null or (.["continue-on-error"] // false) != false))
    then error("actual hosted action must execute and propagate failures")
    elif (["test-todo-action.sh","test-todo-action-blocks.sh","test-todo-action-ci.sh",
      "todo-action-smoke.sh prepare","todo-action-smoke.sh verify"] | all(. as $script |
      [$job.steps[] | select(command == "bash .github/tests/"+$script)] |
      length == 1 and all(.if == null and (.["continue-on-error"] // false) == false and
        (.shell|bash_shell) and (.["working-directory"]|root_directory))) and
      ($job.defaults.run.shell|bash_shell) and ($ci.defaults.run.shell|bash_shell) and
      ($job.defaults.run["working-directory"]|root_directory) and
      ($ci.defaults.run["working-directory"]|root_directory)) | not
    then error("all behavior and fixture checks must execute")
    elif ($job.steps|to_entries|map(select((.value|command) == "bash .github/tests/todo-action-smoke.sh prepare"))|.[0].key) as $prepare |
      ($job.steps|to_entries|map(select(.value.uses == "./actions/create-issues-from-todos"))|.[0].key) as $action |
      ($job.steps|to_entries|map(select((.value|command) == "bash .github/tests/todo-action-smoke.sh verify"))|.[0].key) as $verify |
      ($prepare < $action and $action < $verify) | not
    then error("Docker fixture must prepare before the action and verify afterward")
    elif (.jobs["ci-required-checks"].needs|index("test-create-issues-from-todos")) == null
    then error("action smoke must gate required CI")
    elif any(.jobs["ci-required-checks"].steps[];
      (.env.JOB_RESULTS // ""|contains("needs.test-create-issues-from-todos.result")) and
      (.run // ""|contains("$JOB_RESULTS"))) | not
    then error("required CI must evaluate the action smoke result")
    else true end' "$1"
}
guard "$work/ci.json" >/dev/null
[[ "${2:-}" != --guard-only ]] || exit 0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/ci.json" >"$work/mutated.json"
  if guard "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    echo "FAIL: $label failed for the wrong reason" >&2
    cat "$work/result" >&2
    exit 1
  }
  echo "PASS: rejects $label"
done <<'CASES'
write permission	.jobs["test-create-issues-from-todos"].permissions.issues="write"	only contents-read
job secret	.jobs["test-create-issues-from-todos"].env.EXTRA="${{ secrets.KEY }}"	not forward credentials
workflow secret	.env.EXTRA="${{ secrets[\"KEY\"] }}"	not forward credentials
bulk secrets	.jobs["test-create-issues-from-todos"].env.EXTRA="${{ toJSON(secrets) }}"	not forward credentials
literal token	.jobs["test-create-issues-from-todos"].env.GH_TOKEN="live-token"	not forward credentials
persisted checkout	.jobs["test-create-issues-from-todos"].steps |= map(if (.uses // ""|startswith("actions/checkout@")) then .with["persist-credentials"]=true else . end)	not persist credentials
skipped job	.jobs["test-create-issues-from-todos"].if="false"	scheduling and failure boundary
missing event exclusion	.jobs["test-create-issues-from-todos"].if=null	scheduling and failure boundary
ignored job failure	.jobs["test-create-issues-from-todos"]["continue-on-error"]=true	scheduling and failure boundary
missing behavior	.jobs["test-create-issues-from-todos"].steps |= map(select((.run // ""|contains("test-todo-action.sh"))|not))	all behavior and fixture
ignored behavior failure	.jobs["test-create-issues-from-todos"].steps |= map(if (.run // ""|contains("test-todo-action.sh")) then .["continue-on-error"]=true else . end)	all behavior and fixture
missing Docker fixture	.jobs["test-create-issues-from-todos"].steps |= map(select((.run // ""|contains("todo-action-smoke.sh prepare"))|not))	all behavior and fixture
missing verification	.jobs["test-create-issues-from-todos"].steps |= map(select((.run // ""|contains("todo-action-smoke.sh verify"))|not))	all behavior and fixture
printed prepare	.jobs["test-create-issues-from-todos"].steps |= map(if (.run // ""|contains("todo-action-smoke.sh prepare")) then .run="echo bash .github/tests/todo-action-smoke.sh prepare" else . end)	all behavior and fixture
printed verify	.jobs["test-create-issues-from-todos"].steps |= map(if (.run // ""|contains("todo-action-smoke.sh verify")) then .run="echo bash .github/tests/todo-action-smoke.sh verify" else . end)	all behavior and fixture
fixture custom shell	.jobs["test-create-issues-from-todos"].steps |= map(if (.run // ""|contains("todo-action-smoke.sh prepare")) then .shell="echo {0}" else . end)	all behavior and fixture
job custom shell	.jobs["test-create-issues-from-todos"].defaults.run.shell="true {0}"	all behavior and fixture
workflow custom shell	.defaults.run.shell="true {0}"	all behavior and fixture
fixture shadow directory	.jobs["test-create-issues-from-todos"].steps |= map(if (.run // ""|contains("todo-action-smoke.sh prepare")) then .["working-directory"]="shadow" else . end)	all behavior and fixture
job shadow directory	.jobs["test-create-issues-from-todos"].defaults.run["working-directory"]="shadow"	all behavior and fixture
workflow shadow directory	.defaults.run["working-directory"]="shadow"	all behavior and fixture
swapped fixture order	.jobs["test-create-issues-from-todos"].steps |= map(if .run == "bash .github/tests/todo-action-smoke.sh prepare" then .run="bash .github/tests/todo-action-smoke.sh verify" elif .run == "bash .github/tests/todo-action-smoke.sh verify" then .run="bash .github/tests/todo-action-smoke.sh prepare" else . end)	prepare before the action
action before fixture	.jobs["test-create-issues-from-todos"].steps |= ([.[]|select(.uses == "./actions/create-issues-from-todos")] + [.[]|select(.uses != "./actions/create-issues-from-todos")])	prepare before the action
live project	.jobs["test-create-issues-from-todos"].steps |= map(if .uses == "./actions/create-issues-from-todos" then .with.project="organization/devantler-tech/5" else . end)	live to-do action invocation
live action elsewhere	.jobs.other={steps:[{uses:"./actions/create-issues-from-todos"}]}	live to-do action invocation
equivalent live action path	.jobs.other={steps:[{uses:"./actions/other/../create-issues-from-todos/."}]}	live to-do action invocation
missing hosted action	.jobs["test-create-issues-from-todos"].steps |= map(select(.uses != "./actions/create-issues-from-todos"))	actual hosted action
skipped hosted action	.jobs["test-create-issues-from-todos"].steps |= map(if .uses == "./actions/create-issues-from-todos" then .if="false" else . end)	actual hosted action
missing required dependency	.jobs["ci-required-checks"].needs |= map(select(. != "test-create-issues-from-todos"))	gate required CI
missing required verdict	.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-create-issues-from-todos.result";"needs.other.result") else . end)	evaluate the action smoke result
CASES
echo 'PASS: 30 CI mutations preserve the offline to-do action smoke boundary'
