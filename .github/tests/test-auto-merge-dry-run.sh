#!/usr/bin/env bash
# Removing a job guard or bypassing required fixture execution must fail CI.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "${1:-$root/.github/workflows/enable-auto-merge.yaml}" >"$work/workflow.json"
yq -o=json '.' "${2:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"
jq -n --slurpfile workflow "$work/workflow.json" --slurpfile ci "$work/ci.json" \
  '{workflow:$workflow[0],ci:$ci[0]}' >"$work/bundle.json"
condition="\${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"
guard() {
  jq -e --arg condition "$condition" '
    def runnable: .if == null and (.["continue-on-error"] // false) == false and
      (.shell == null or .shell == "bash") and .["working-directory"] == null;
    .workflow as $w | .ci as $ci | $w.jobs["dry-run"] as $job |
    if $w.on.workflow_call.inputs["dry-run"].type != "boolean" or
      $w.on.workflow_call.inputs["dry-run"].default != false or
      $w.on.workflow_call.secrets.APP_PRIVATE_KEY.required != false
    then error("dry-run must be default-off and secret-free")
    elif ($w.jobs["auto-merge"].if | gsub("\\s";"")) != "!inputs.dry-run&&needs.eligibility.outputs.eligible=='\''true'\''&&(github.event_name=='\''pull_request'\''||inputs.enforce-review-gates||vars.ENFORCE_MERGE_GATES=='\''true'\'')" or
      $w.jobs["disarm-untrusted-update"].if != "!inputs.dry-run && needs.eligibility.outputs.disarm == '\''true'\''"
    then error("dry-run must exclude every privileged job")
    elif ($w.concurrency.group | endswith("${{ inputs.dry-run && format('\''-dry-run-{0}-{1}'\'', github.run_id, github.run_attempt) || '\'''\'' }}")) | not
    then error("dry-run must isolate its concurrency lane")
    elif ($w.concurrency["cancel-in-progress"] | startswith("${{ !inputs.dry-run && ")) | not
    then error("dry-run must never cancel a live evaluation")
    elif $job.if != "inputs.dry-run" or $job.needs != null or
      ($job["continue-on-error"] // false) != false
    then error("dry-run must execute independently")
    elif $job.permissions != {contents:"read"} or
      ($job | tostring | test("secrets\\.|create-github-app-token|github.token")) or
      ($w.env | tostring | test("secrets\\.|TOKEN|PRIVATE_KEY"))
    then error("offline job must have only read permission and no credentials")
    elif [$job.steps[] | select(.uses != null)] | length != 2
    then error("offline job must use only hardening and checkout actions")
    elif [$job.steps[] | select(.with.path == ".devantler-tech-actions" and
      .with.repository == "${{ job.workflow_repository }}" and
      .with.ref == "${{ job.workflow_sha }}" and .with["persist-credentials"] == false and .if == null)] | length != 1
    then error("fixture must come from this immutable workflow commit")
    elif (["test-auto-merge-fixture.sh","test-enable-auto-merge-author-gate.sh",
      "test-enable-auto-merge-pentad-gate.sh","test-disarm-auto-merge.sh",
      "test-is-current-pull-request-lifecycle.sh"] | all(. as $script |
        [$job.steps[] | select(.run == "bash .github/tests/"+$script)] |
        length == 1 and all(runnable))) | not or
      $job.defaults.run != {shell:"bash", "working-directory":".devantler-tech-actions"}
    then error("actual offline decision suites must execute")
    elif (["test-enable-auto-merge","test-enable-auto-merge-actor-trust","test-enable-auto-merge-queued"] |
      all(. as $name | $ci.jobs[$name].uses == "./.github/workflows/enable-auto-merge.yaml" and
        $ci.jobs[$name].with["dry-run"] == true and $ci.jobs[$name].secrets == null and
        $ci.jobs[$name].if == $condition and $ci.jobs[$name].needs == null and
        ($ci.jobs[$name]["continue-on-error"] // false) == false and
        ($ci.jobs["ci-required-checks"].needs | index($name)) != null and
        any($ci.jobs["ci-required-checks"].steps[]; (.env.JOB_RESULTS // "" |
          contains("needs."+$name+".result")) and (.run // "" | contains("$JOB_RESULTS"))))) | not
    then error("secret-free reusable calls must gate required CI")
    elif (["test-auto-merge-dry-run.sh","test-auto-merge-fixture.sh","test-auto-merge-fixture-controls.sh"] | all(. as $script |
      [$ci.jobs["test-enable-auto-merge-author-gate"].steps[] |
        select(.run == "bash .github/tests/"+$script)] | length == 1 and all(runnable))) | not
    then error("boundary and behavior regressions must execute in CI")
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
live path changed	.workflow.on.workflow_call.inputs["dry-run"].default=true	default-off
approval boundary lost	.workflow.jobs["auto-merge"].if |= sub("!inputs.dry-run && ";"")	privileged job
disarm boundary lost	.workflow.jobs["disarm-untrusted-update"].if |= sub("!inputs.dry-run && ";"")	privileged job
shared concurrency lane	.workflow.concurrency.group |= sub("\\$\\{\\{ inputs.dry-run.*$";"")	isolate its concurrency lane
live cancellation	.workflow.concurrency["cancel-in-progress"] |= sub("!inputs.dry-run && ";"")	never cancel
missing offline job	.workflow.jobs |= del(.["dry-run"])	execute independently
skipped offline job	.workflow.jobs["dry-run"].if="false"	execute independently
blocked offline job	.workflow.jobs["dry-run"].needs="auto-merge"	execute independently
ignored offline failure	.workflow.jobs["dry-run"]["continue-on-error"]=true	execute independently
write token	.workflow.jobs["dry-run"].permissions.contents="write"	only read permission
App key	.workflow.jobs["dry-run"].env.KEY="${{ secrets.APP_PRIVATE_KEY }}"	no credentials
implicit token	.workflow.jobs["dry-run"].permissions=null	only read permission
token forwarding	.workflow.jobs["dry-run"].env.GH_TOKEN="${{ github.token }}"	no credentials
extra action	.workflow.jobs["dry-run"].steps += [{uses:"some/action@main"}]	only hardening and checkout
mutable checkout	.workflow.jobs["dry-run"].steps |= map(if .with.path then .with.ref="main" else . end)	immutable workflow commit
persisted token	.workflow.jobs["dry-run"].steps |= map(if .with.path then .with["persist-credentials"]=true else . end)	immutable workflow commit
fixture bypass	.workflow.jobs["dry-run"].steps |= map(if .run == "bash .github/tests/test-auto-merge-fixture.sh" then .run="echo PASS" else . end)	decision suites
fixture failure ignored	.workflow.jobs["dry-run"].steps |= map(if .run == "bash .github/tests/test-auto-merge-fixture.sh" then .["continue-on-error"]=true else . end)	decision suites
shadow working directory	.workflow.jobs["dry-run"].defaults.run["working-directory"]="shadow"	decision suites
fake shell	.workflow.jobs["dry-run"].defaults.run.shell="true {0}"	decision suites
default secret	.ci.jobs["test-enable-auto-merge"].secrets="inherit"	secret-free reusable calls
actor live mode	.ci.jobs["test-enable-auto-merge-actor-trust"].with["dry-run"]=false	secret-free reusable calls
queued secret	.ci.jobs["test-enable-auto-merge-queued"].secrets.APP_PRIVATE_KEY="key"	secret-free reusable calls
queued test skipped	.ci.jobs["test-enable-auto-merge-queued"].if="false"	secret-free reusable calls
lost aggregation	.ci.jobs["ci-required-checks"].needs |= map(select(. != "test-enable-auto-merge"))	gate required CI
lost result	.ci.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-enable-auto-merge.result";"needs.other.result") else . end)	gate required CI
boundary test skipped	.ci.jobs["test-enable-auto-merge-author-gate"].steps |= map(if .run == "bash .github/tests/test-auto-merge-dry-run.sh" then .if="false" else . end)	regressions must execute
behavior test lost	.ci.jobs["test-enable-auto-merge-author-gate"].steps |= map(select(.run != "bash .github/tests/test-auto-merge-fixture.sh"))	regressions must execute
CASES
echo "PASS: auto-merge dry-run boundary rejects $count independent regressions"
