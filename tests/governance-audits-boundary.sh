#!/usr/bin/env bash
# Routine reporting must not turn a skipped/incomplete audit into recovery.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Reporters resolve their action from the workflow source, including on audit failure.
verify_reporter() {
  jq -e --arg job "$2" '
    .jobs[$job] as $report |
    if $report.permissions != {contents:"read",issues:"write"}
    then error("reporter must have only source read and issue reporting authority")
    elif ($report.steps | length) != 3 or
      $report.steps[0].uses != "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1" or
      $report.steps[0].if != null or $report.steps[0].env != null or
      $report.steps[0]["continue-on-error"] != null
    then error("reporter must first check out its source unconditionally")
    elif $report.steps[0].with != {
      repository:"${{ github.repository }}",ref:"${{ github.workflow_sha }}",
      path:".devantler-tech-actions","persist-credentials":false}
    then error("reporter checkout must bind its exact workflow source without persisted credentials")
    elif any($report.steps[1:][]; .uses != "./.devantler-tech-actions/actions/upsert-issue" or
      .env != null or .["continue-on-error"] != null)
    then error("both reporting outcomes must invoke the same local source action")
    else true end
  ' "$1"
}
while IFS=$'\t' read -r file job; do
  yq -o=json '.' "$root/.github/workflows/$file" >"$work/reporter.json"
  verify_reporter "$work/reporter.json" "$job" >/dev/null
  while IFS=$'\t' read -r name mutation diagnostic; do
    jq --arg job "$job" "$mutation" "$work/reporter.json" >"$work/mutated.json"
    if verify_reporter "$work/mutated.json" "$job" >"$work/result" 2>&1; then
      echo "FAIL: $file accepted $name" >&2
      exit 1
    fi
    grep -qF "$diagnostic" "$work/result" || {
      echo "FAIL: $file rejected $name for the wrong reason" >&2
      cat "$work/result" >&2
      exit 1
    }
    echo "PASS: $file rejects $name"
  done <<'REPORTER_CASES'
missing source authority	.jobs[$job].permissions.contents=null	only source read
content write authority	.jobs[$job].permissions.contents="write"	only source read
missing checkout	.jobs[$job].steps |= .[1:]	first check out
skipped checkout	.jobs[$job].steps[0].if="false"	first check out
ignored checkout failure	.jobs[$job].steps[0]["continue-on-error"]=true	first check out
mutable source	.jobs[$job].steps[0].with.ref="main"	exact workflow source
foreign source	.jobs[$job].steps[0].with.repository="outside/fixture"	exact workflow source
incorrect source path	.jobs[$job].steps[0].with.path="."	exact workflow source
persisted credentials	.jobs[$job].steps[0].with["persist-credentials"]=true	exact workflow source
remote action	.jobs[$job].steps[1].uses="devantler-tech/.github/actions/upsert-issue@498fb4b11f129928d3af9a90e9c5a46f1c4dbd77"	same local source action
wrong action path	.jobs[$job].steps[2].uses="./actions/upsert-issue"	same local source action
source-tree substitution	.jobs[$job].steps[1].uses="$/.devantler-tech-actions/actions/upsert-issue"	same local source action
ignored report failure	.jobs[$job].steps[2]["continue-on-error"]=true	same local source action
REPORTER_CASES
done <<'REPORTERS'
governance-audits.yaml	report
repository-coverage-check.yaml	report-coverage-check
repository-drift-check.yaml	report-drift-check
REPORTERS
[[ -f "$root/.github/workflows/governance-audits.yaml" ]] || {
  echo 'FAIL: routine workflow is missing' >&2
  exit 1
}
yq -o=json '.' "$root/.github/workflows/governance-audits.yaml" >"$work/source.json"
verify() {
  jq -e '
    def normalized: gsub("\\s+";" ") | sub(" $";"");
    (.on | keys == ["schedule","workflow_dispatch"]) and
    .on.schedule == [{cron:"17 6 * * *"}] and
    .on.workflow_dispatch == {} and
    .permissions == {} and .env == null and .defaults == null and
    (.jobs | keys == ["admit","audit","report"]) and
    .jobs.admit.permissions == {contents:"read"} and
    (.jobs.admit.if | normalized) ==
      "github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (github.event_name == '\''schedule'\'' || github.event_name == '\''workflow_dispatch'\'')" and
    .jobs.admit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.admit.steps[1].with["persist-credentials"] == false and
    .jobs.admit.steps[2].run == "bash scripts/governance-audit-admission.sh" and
    .jobs.admit.outputs.enabled == "${{ steps.admission.outputs.enabled }}" and
    .jobs.admit.steps[2].env == null and
    .jobs.audit.needs == ["admit"] and
    (.jobs.audit.if | normalized) == "needs.admit.outputs.enabled == '\''true'\''" and
    .jobs.audit.permissions == {contents:"read"} and
    .jobs.audit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.audit.steps[1].with["persist-credentials"] == false and
    .jobs.audit.steps[2].with == {
      "client-id":"${{ vars.APP_CLIENT_ID }}","private-key":"${{ secrets.APP_PRIVATE_KEY }}",
      owner:"devantler-tech","permission-metadata":"read","permission-administration":"read"} and
    .jobs.audit.steps[3].env == {
      GH_TOKEN:"${{ steps.audit-token.outputs.token }}",
      GH_INSTALLATION_ID:"${{ steps.audit-token.outputs.installation-id }}",
      GH_APP_CLIENT_ID:"${{ vars.APP_CLIENT_ID }}",GH_APP_PRIVATE_KEY:"${{ secrets.APP_PRIVATE_KEY }}"} and
    .jobs.audit.steps[3].run == "bash scripts/run-governance-audits.sh" and
    .jobs.report.needs == ["admit","audit"] and
    (.jobs.report.if | normalized) ==
      "!cancelled() && github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (github.event_name == '\''schedule'\'' || github.event_name == '\''workflow_dispatch'\'') && (needs.admit.result == '\''failure'\'' || needs.admit.outputs.enabled == '\''true'\'')" and
    .jobs.report.permissions == {contents:"read",issues:"write"} and .jobs.report.env == null and
    (.jobs.report.steps | length == 3) and
    .jobs.report.steps[1].if == "needs.admit.result != '\''success'\'' || needs.audit.result != '\''success'\''" and
    .jobs.report.steps[2].if == "needs.admit.result == '\''success'\'' && needs.audit.result == '\''success'\''" and
    .jobs.report.steps[1].with.open == "true" and .jobs.report.steps[2].with.open == "false" and
    (.jobs.report.steps[1].with | keys == ["body","open","repository","title"]) and
    (.jobs.report.steps[2].with | keys == ["body","close-comment","open","repository","title"]) and
    all(.jobs.report.steps[1:][]; .with.repository == "devantler-tech/.github" and
      .with.title == "Scheduled governance audits need attention" and
      (.with.body | startswith("> 🤖 Generated by the Agentic Engineer")) and .env == null and
      .uses == "./.devantler-tech-actions/actions/upsert-issue") and
    all(.jobs[]; .["continue-on-error"] == null and .defaults == null) and
    all(.jobs[].steps[]; .shell == null and .["continue-on-error"] == null) and
    all(.jobs.admit.steps[],.jobs.audit.steps[]; .if == null and .["continue-on-error"] == null and
      (if has("uses") then (.uses | test("@[0-9a-f]{40}$")) else true end)) and
    (.jobs.admit.steps | length == 3) and (.jobs.audit.steps | length == 4)
  ' "$1" >/dev/null 2>&1
}
verify "$work/source.json" || {
  echo 'FAIL: routine audit lost its admission, read scope or failure reporting' >&2
  exit 1
}
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$work/source.json" >"$work/mutated.json"
  if verify "$work/mutated.json"; then
    echo "FAIL: accepted $name" >&2
    exit 1
  fi
  echo "PASS: rejects $name"
done <<'CASES'
PR admission	.on.pull_request={}
retired rollout input	.on.workflow_dispatch.inputs["run-audit"]={type:"boolean",default:false}
untrusted admission	.jobs.admit.if="true"
mutable admission source	.jobs.admit.steps[1].with.ref="main"
skipped admission	.jobs.admit.steps[2].if="false"
forged output	.jobs.admit.outputs.enabled="true"
unguarded audit	.jobs.audit.if="true"
write App	.jobs.audit.steps[2].with["permission-administration"]="write"
partial census	.jobs.audit.steps[2].with.repositories=".github"
wrong installation	.jobs.audit.steps[3].env.GH_INSTALLATION_ID="1"
incomplete audit	.jobs.audit.steps[3].run="bash scripts/check-repository-admin-teams.sh"
ignored audit	.jobs.audit["continue-on-error"]=true
skipped reporter	.jobs.report.if="false"
reporter App key	.jobs.report.env.KEY="${{ secrets.APP_PRIVATE_KEY }}"
reporter content authority	.jobs.report.permissions.contents="write"
skipped audit closes issue	.jobs.report.steps[2].if="needs.audit.result != 'failure'"
cancelled audit reports recovery	.jobs.report.if="always()"
untrusted report recipient	.jobs.report.steps[1].with.repository="outside/fixture"
mutable reporter	.jobs.report.steps[1].uses="devantler-tech/.github/actions/upsert-issue@main"
masked report failure	.jobs.report.steps[1]["continue-on-error"]=true
skipped audit shell	.jobs.audit.steps[3].shell="true {0}"
ignored workflow shell	.defaults.run.shell="true {0}"
reporter App token	.jobs.report.steps[1].with["github-token"]="${{ secrets.APP_PRIVATE_KEY }}"
CASES
echo 'PASS: routine governance admission, read authority and report transitions are protected'
