#!/usr/bin/env bash
# #348: catalogue release tests must execute without production write credentials.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
workflow="${1:-$root/.github/workflows/create-release.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$workflow" >"$work/workflow.json"
yq -o=json '.' "$ci" >"$work/ci.json"
jq -n --slurpfile w "$work/workflow.json" --slurpfile c "$work/ci.json" \
  '{workflow:$w[0],ci:$c[0]}' >"$work/bundle.json"
condition="\${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"
guard() {
  jq -e --arg condition "$condition" '
    def runnable: .if == null and (.["continue-on-error"] // false) == false and
      (.shell == null or .shell == "bash") and .["working-directory"] == null;
    .workflow as $w | .ci as $c | $w.jobs["offline-test"] as $j |
    if $w.on.workflow_call.inputs["offline-test"].type != "boolean" or
      $w.on.workflow_call.inputs["offline-test"].default != false or
      $w.on.workflow_call.inputs["dry-run"].default != false or
      $w.on.workflow_call.secrets.APP_PRIVATE_KEY.required != false
    then error("offline-test must be default-off and secret-free")
    elif $w.jobs.release.if != "!inputs.offline-test"
    then error("offline-test must exclude the production release job")
    elif $j.if != "inputs.offline-test" or $j.needs != null or
      ($j["continue-on-error"] // false) != false
    then error("offline-test must execute independently")
    elif $j.permissions != {contents:"read"} or
      ([$j,$w.env // {}] | tostring | test("\\bsecrets\\b|create-github-app-token|github[.]token|GH_TOKEN|GITHUB_TOKEN|PRIVATE_KEY";"i"))
    then error("offline-test must have read permission and no credentials")
    elif [$j.steps[] | select(.uses != null)] | length != 3
    then error("offline-test must use only hardening, checkout and Node setup")
    elif [$j.steps[] | select(.with.repository == "${{ job.workflow_repository }}" and
      .with.ref == "${{ job.workflow_sha }}" and .with.path == ".devantler-tech-actions" and
      .with["persist-credentials"] == false and .if == null)] | length != 1
    then error("offline-test must check out its immutable workflow commit")
    elif ([$j.steps[] | select(.name == "🔎 Validate offline mode") |
      select(runnable and .env.DRY_RUN == "${{ inputs.dry-run }}" and
        (.run | contains("[[ \"$DRY_RUN\" == true ]]")) and (.run | contains("exit 1")))] | length) != 1
    then error("offline-test must require dry-run before executing")
    elif $j.defaults.run != {shell:"bash","working-directory":".devantler-tech-actions"} or
      ([$j.steps[] | select(.run == "bash .github/tests/create-release-fixture.sh") |
        select(runnable and .env.DISABLE_ISSUE_SIDE_EFFECTS == "${{ inputs.disable-issue-side-effects }}")] | length) != 1
    then error("offline release decisions must execute with the caller hook setting")
    elif (["test-create-release","test-create-release-no-issue-side-effects"] | all(. as $name |
      $c.jobs[$name].uses == "./.github/workflows/create-release.yaml" and
      $c.jobs[$name].with["offline-test"] == true and $c.jobs[$name].with["dry-run"] == true and
      $c.jobs[$name].secrets == null and $c.jobs[$name].permissions == {contents:"read"} and
      $c.jobs[$name].if == $condition and $c.jobs[$name].needs == null and
      ($c.jobs[$name]["continue-on-error"] // false) == false and
      ($c.jobs["ci-required-checks"].needs | index($name)) != null and
      any($c.jobs["ci-required-checks"].steps[]; (.env.JOB_RESULTS // "" |
        contains("needs."+$name+".result")) and (.run // "" | contains("$JOB_RESULTS"))))) | not
    then error("secret-free release calls must gate required CI")
    elif (["test-create-release-offline.sh","test-create-release-fixture-controls.sh"] | all(. as $script |
      [$c.jobs["test-create-release-config"].steps[] | select(.run == "bash .github/tests/"+$script)] |
        length == 1 and all(runnable))) | not
    then error("offline boundary regressions must execute in CI")
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
required secret	.workflow.on.workflow_call.secrets.APP_PRIVATE_KEY.required=true	secret-free
changed default	.workflow.on.workflow_call.inputs["offline-test"].default=true	default-off
consumer preview changed	.workflow.on.workflow_call.inputs["dry-run"].default=true	default-off
production execution	.workflow.jobs.release.if=null	exclude the production
skipped fixture	.workflow.jobs["offline-test"].if="false"	execute independently
fixture prerequisite	.workflow.jobs["offline-test"].needs="release"	execute independently
ignored failure	.workflow.jobs["offline-test"]["continue-on-error"]=true	execute independently
write permission	.workflow.jobs["offline-test"].permissions.contents="write"	read permission
inherited permission	.workflow.jobs["offline-test"].permissions=null	read permission
App key	.workflow.jobs["offline-test"].env.KEY="${{ secrets.APP_PRIVATE_KEY }}"	no credentials
bracket secret	.workflow.jobs["offline-test"].env.KEY="${{ secrets['APP_PRIVATE_KEY'] }}"	no credentials
uppercase secret	.workflow.jobs["offline-test"].env.KEY="${{ SECRETS.APP_PRIVATE_KEY }}"	no credentials
serialized secrets	.workflow.jobs["offline-test"].env.KEY="${{ toJSON(secrets) }}"	no credentials
App mint	.workflow.jobs["offline-test"].steps += [{uses:"actions/create-github-app-token@sha"}]	no credentials
token forwarding	.workflow.jobs["offline-test"].env.GH_TOKEN="${{ github.token }}"	no credentials
mutable checkout	.workflow.jobs["offline-test"].steps |= map(if .with.path then .with.ref="main" else . end)	immutable workflow commit
persisted token	.workflow.jobs["offline-test"].steps |= map(if .with.path then .with["persist-credentials"]=true else . end)	immutable workflow commit
fixture bypass	.workflow.jobs["offline-test"].steps |= map(if .run == "bash .github/tests/create-release-fixture.sh" then .run="echo PASS" else . end)	decisions must execute
hook setting lost	.workflow.jobs["offline-test"].steps |= map(if .run then .env.DISABLE_ISSUE_SIDE_EFFECTS="true" else . end)	caller hook setting
default App key	.ci.jobs["test-create-release"].secrets.APP_PRIVATE_KEY="key"	secret-free release calls
inherited secrets	.ci.jobs["test-create-release-no-issue-side-effects"].secrets="inherit"	secret-free release calls
live mode	.ci.jobs["test-create-release"].with["offline-test"]=false	secret-free release calls
write caller	.ci.jobs["test-create-release"].permissions.contents="write"	secret-free release calls
lost aggregation	.ci.jobs["ci-required-checks"].needs |= map(select(. != "test-create-release"))	gate required CI
lost result	.ci.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-create-release.result";"needs.other.result") else . end)	gate required CI
boundary skipped	.ci.jobs["test-create-release-config"].steps |= map(if .run == "bash .github/tests/test-create-release-offline.sh" then .if="false" else . end)	regressions must execute
invalid offline mode	.workflow.jobs["offline-test"].steps |= map(select(.name != "🔎 Validate offline mode"))	require dry-run
behavior controls skipped	.ci.jobs["test-create-release-config"].steps |= map(select(.run != "bash .github/tests/test-create-release-fixture-controls.sh"))	regressions must execute
CASES
echo "PASS: release offline boundary rejects $count independent regressions"
