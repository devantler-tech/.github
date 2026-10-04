#!/usr/bin/env bash
# A required real-scanner fixture must execute without live credentials.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "${1:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"
guard() {
  jq -e '
    def command: .run // "" | gsub("^\\s+|\\s+$";"");
    . as $ci | .jobs["test-todo-scanner"] as $job |
    if ($job|type) != "object" then error("real scanner job is missing")
    elif $job.permissions != {contents:"read"} then error("scanner job must be contents-read-only")
    elif ([$ci.env // {},$job] | tostring | test("\\bsecrets\\b|github[.]token|GH_TOKEN|GITHUB_TOKEN";"i"))
    then error("scanner job must not forward live credentials")
    elif $job.if != "${{ github.event_name != '\''merge_group'\'' && !startsWith(github.event.head_commit.message, '\''chore(main): release '\'') }}" or
      ($job["continue-on-error"] // false) != false
    then error("scanner job must preserve its scheduling and failure boundary")
    elif ([$job.steps[]|select((.uses // "")|startswith("actions/checkout@"))] |
      length != 1 or any(.with["persist-credentials"] != false))
    then error("scanner checkout must disable persisted credentials")
    elif (["bash .github/tests/test-todo-scanner.sh", "bash .github/tests/test-todo-scanner-controls.sh", "go test -C .scripts/todo-guard -race ./..."] |
      any(. as $command | [$job.steps[]|select(command == $command)] |
        length != 1 or any(.if != null or (.shell != null and .shell != "bash") or
          (."continue-on-error" // false) != false or ."working-directory" != null)))
    then error("real scanner command must execute and propagate failure")
    elif ([$ci.defaults.run // {},$job.defaults.run // {}] | any(
      (.shell != null and .shell != "bash") or (."working-directory" != null and ."working-directory" != ".")))
    then error("scanner defaults must preserve execution")
    elif (.jobs["ci-required-checks"].needs | index("test-todo-scanner")) == null
    then error("scanner must gate required CI")
    elif ([.jobs["ci-required-checks"].steps[] | select(
      (.env.JOB_RESULTS // ""|contains("needs.test-todo-scanner.result")) and
      (.run // ""|contains("$JOB_RESULTS")))] | length) == 0
    then error("required CI must evaluate scanner result")
    else true end' "$1" >/dev/null
}
guard "$work/ci.json"
[[ "${2:-}" != --guard-only ]] || exit 0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/ci.json" >"$work/mutated.json"
  if guard "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2; exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || { cat "$work/result"; exit 1; }
done <<'CASES'
write permission	.jobs["test-todo-scanner"].permissions.issues="write"	contents-read-only
live credential	.jobs["test-todo-scanner"].env.TOKEN="${{ secrets.APP_PRIVATE_KEY }}"	live credentials
persisted checkout	.jobs["test-todo-scanner"].steps |= map(if (.uses // ""|startswith("actions/checkout@")) then .with["persist-credentials"]=true else . end)	persisted credentials
missing scanner	.jobs["test-todo-scanner"].steps |= map(select((.run // ""|contains("test-todo-scanner.sh"))|not))	command must execute
printed scanner	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner.sh")) then .run="echo bash .github/tests/test-todo-scanner.sh" else . end)	command must execute
missing native controls	.jobs["test-todo-scanner"].steps |= map(select((.run // ""|contains("test-todo-scanner-controls.sh"))|not))	command must execute
printed native controls	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner-controls.sh")) then .run="echo bash .github/tests/test-todo-scanner-controls.sh" else . end)	command must execute
skipped native controls	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner-controls.sh")) then .if="false" else . end)	command must execute
ignored native control failure	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner-controls.sh")) then .["continue-on-error"]=true else . end)	command must execute
skipped scanner	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner.sh")) then .if="false" else . end)	command must execute
ignored failure	.jobs["test-todo-scanner"]["continue-on-error"]=true	failure boundary
ignored scanner failure	.jobs["test-todo-scanner"].steps |= map(if (.run // ""|contains("test-todo-scanner.sh")) then .["continue-on-error"]=true else . end)	command must execute
custom shell	.jobs["test-todo-scanner"].defaults.run.shell="true {0}"	defaults must preserve
shadow directory	.jobs["test-todo-scanner"].defaults.run["working-directory"]="shadow"	defaults must preserve
missing required dependency	.jobs["ci-required-checks"].needs |= map(select(. != "test-todo-scanner"))	gate required CI
missing required result	.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-todo-scanner.result";"needs.other.result") else . end)	evaluate scanner result
CASES
echo 'PASS: 16 CI mutations preserve the real scanner boundary'
