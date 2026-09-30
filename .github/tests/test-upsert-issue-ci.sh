#!/usr/bin/env bash
# Keep issue lifecycle self-tests offline and without a live write credential.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "${1:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"

guard() {
  jq -e '
    . as $workflow |
    if [.jobs | to_entries[] | .key as $job | .value.steps[]? |
      select((.uses // "") | test("(^|/)upsert-issue(@|$)")) |
      select($job != "test-upsert-issue" or .with["github-token"] != "offline-fixture" or
        .with.repository != "offline/fixture")] | length > 0
    then error("live upsert-issue invocation in catalogue CI")
    elif (.jobs["test-upsert-issue"] | type) != "object"
    then error("offline upsert-issue job is missing")
    elif .jobs["test-upsert-issue"].permissions != {"contents":"read"}
    then error("offline issue job must have only contents-read permission")
    elif ([.env // {}, .jobs["test-upsert-issue"]] | tostring |
      test("\\bsecrets\\b|GH_TOKEN|GITHUB_TOKEN|private-key"; "i"))
    then error("offline issue job must not forward credentials")
    elif ([.jobs["test-upsert-issue"].steps[] |
      select((.uses // "") | startswith("actions/checkout@"))] |
      length == 0 or any(.with["persist-credentials"] != false))
    then error("offline issue checkout must disable persisted credentials")
    elif (.jobs["test-upsert-issue"].if != null or
      (.jobs["test-upsert-issue"]["continue-on-error"] // false) != false)
    then error("offline issue job must run and propagate failures")
    elif (["test-upsert-issue-reopen.sh", "test-upsert-issue-ci.sh",
      "upsert-issue-smoke.sh prepare", "upsert-issue-smoke.sh verify"] | all(. as $script |
      any($workflow.jobs["test-upsert-issue"].steps[];
        (.run // "" | contains("bash .github/tests/" + $script)) and
        .if == null and (."continue-on-error" // false) == false))) | not
    then error("offline behavior and boundary checks must run and propagate failures")
    elif any(.jobs["test-upsert-issue"].steps[];
      .uses == "./actions/upsert-issue" and .if == null and
      (."continue-on-error" // false) == false) | not
    then error("hosted offline composite-action smoke test must run")
    elif (.jobs["ci-required-checks"].needs | index("test-upsert-issue")) == null
    then error("offline issue job must gate required CI")
    elif any(.jobs["ci-required-checks"].steps[];
      (.env.JOB_RESULTS // "" | contains("needs.test-upsert-issue.result")) and
      (.run // "" | contains("$JOB_RESULTS"))) | not
    then error("required CI must evaluate the offline issue result")
    else true end
  ' "$1"
}

guard "$work/ci.json" >/dev/null
[[ "${2:-}" != --guard-only ]] || exit 0

# Mutate the real CI definition; each unsafe boundary must fail for its own reason.
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
write permission	.jobs["test-upsert-issue"].permissions.issues="write"	only contents-read
job secret	.jobs["test-upsert-issue"].env.EXTRA="${{ secrets[\"TOKEN\"] }}"	not forward credentials
workflow secret	.env.EXTRA="${{ secrets.TOKEN }}"	not forward credentials
bulk secret forwarding	.jobs["test-upsert-issue"].env.EXTRA="${{ toJSON(secrets) }}"	not forward credentials
literal token environment	.jobs["test-upsert-issue"].env.GH_TOKEN="credential"	not forward credentials
persisted checkout	.jobs["test-upsert-issue"].steps |= map(if (.uses // "" | startswith("actions/checkout@")) then .with["persist-credentials"]=true else . end)	disable persisted credentials
missing behavior	.jobs["test-upsert-issue"].steps |= map(select((.run // "" | contains("test-upsert-issue-reopen.sh")) | not))	behavior and boundary checks
ignored failure	.jobs["test-upsert-issue"].steps |= map(if (.run // "" | contains("test-upsert-issue-reopen.sh")) then ."continue-on-error"=true else . end)	behavior and boundary checks
skipped job	.jobs["test-upsert-issue"].if="false"	job must run
missing required dependency	.jobs["ci-required-checks"].needs |= map(select(. != "test-upsert-issue"))	gate required CI
missing required verdict	.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-upsert-issue.result"; "needs.other.result") else . end)	evaluate the offline issue result
live action elsewhere	.jobs.unexpected={steps:[{uses:"./actions/upsert-issue"}]}	live upsert-issue invocation
live smoke token	.jobs["test-upsert-issue"].steps |= map(if .uses == "./actions/upsert-issue" then .with["github-token"]="live-token" else . end)	live upsert-issue invocation
live smoke repository	.jobs["test-upsert-issue"].steps |= map(if .uses == "./actions/upsert-issue" then .with.repository="devantler-tech/.github" else . end)	live upsert-issue invocation
missing hosted smoke	.jobs["test-upsert-issue"].steps |= map(select(.uses != "./actions/upsert-issue"))	hosted offline composite-action
CASES
echo "PASS: upsert-issue CI is offline, read-only and required"
