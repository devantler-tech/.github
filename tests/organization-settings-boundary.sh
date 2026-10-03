#!/usr/bin/env bash
# Reject restored mutation authority or candidate-controlled execution sources.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/organization-settings-audit.yaml" >"$work/source.json"
verify() {
  jq -e '
    (.on | keys == ["workflow_dispatch"]) and .permissions == {} and .env == null and
    .on.workflow_dispatch.inputs["run-audit"].type == "boolean" and
    .on.workflow_dispatch.inputs["run-audit"].default == false and
    (.jobs | keys == ["audit"]) and
    (.jobs.audit.if | gsub("\\s+";" ") | sub(" $";"")) ==
      "github.event_name == '\''workflow_dispatch'\'' && github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (inputs.run-audit == true || inputs.run-audit == '\''true'\'')" and
    .jobs.audit.permissions == {contents:"read"} and .jobs.audit.env == null and
    .jobs.audit["continue-on-error"] == null and
    (.jobs.audit.steps | length == 4) and
    (.jobs.audit.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$")) and
    (.jobs.audit.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
    .jobs.audit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.audit.steps[1].with["persist-credentials"] == false and
    (.jobs.audit.steps[2].uses | test("^actions/create-github-app-token@[0-9a-f]{40}$")) and
    .jobs.audit.steps[2].id == "audit-token" and
    .jobs.audit.steps[2].with == {
      "client-id":"${{ vars.APP_CLIENT_ID }}",
      "private-key":"${{ secrets.APP_PRIVATE_KEY }}",
      owner:"devantler-tech", repositories:".github",
      "permission-metadata":"read",
      "permission-organization-administration":"read"} and
    .jobs.audit.steps[3].run == "bash scripts/check-organization-settings.sh" and
    .jobs.audit.steps[3].env == {GH_TOKEN:"${{ steps.audit-token.outputs.token }}"} and
    all(.jobs.audit.steps[]; .if == null and .["continue-on-error"] == null)
  ' "$1" >/dev/null 2>&1
}
verify "$work/source.json" || {
  echo 'FAIL: organization audit must use main, opt-in and narrowly scoped read authority' >&2
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
default activation	.on.workflow_dispatch.inputs["run-audit"].default=true
PR trigger	.on.pull_request={}
unguarded job	.jobs.audit.if="true"
workflow write	.permissions.contents="write"
job write	.jobs.audit.permissions.contents="write"
App write	.jobs.audit.steps[2].with["permission-organization-administration"]="write"
inherited App authority	del(.jobs.audit.steps[2].with["permission-organization-administration"])
broad repository scope	del(.jobs.audit.steps[2].with.repositories)
mutable source	.jobs.audit.steps[1].with.ref="main"
persisted credential	.jobs.audit.steps[1].with["persist-credentials"]=true
replaced token	.jobs.audit.steps[3].env.GH_TOKEN="${{ secrets.APP_PRIVATE_KEY }}"
ignored worker failure	.jobs.audit.steps[3]["continue-on-error"]=true
skipped worker	.jobs.audit.steps[3].if="false"
ambient secret	.env.API_KEY="${{ secrets.APP_PRIVATE_KEY }}"
second writer	.jobs.writer={permissions:{contents:"write"}}
mutable dependency	.jobs.audit.steps[2].uses="actions/create-github-app-token@main"
CASES
echo 'PASS: organization settings audit preserves activation, source and read authority'
