#!/usr/bin/env bash
# Reject restored mutation authority or candidate-controlled execution sources.
# The audit's token authority lives in its GitHub token broker trust policy
# (devantler-tech/monorepo ADR 0020), so both the workflow and that policy are
# pinned, and each is mutated on its own.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/organization-settings-audit.yaml" >"$work/source.json"
yq -o=json '.' "$root/.github/chainguard/organization-settings-audit.sts.yaml" >"$work/policy.json"
verify() {
  jq -e '
    (.on | keys == ["workflow_dispatch"]) and .permissions == {} and .env == null and
    .on.workflow_dispatch.inputs["run-audit"].type == "boolean" and
    .on.workflow_dispatch.inputs["run-audit"].default == false and
    (.jobs | keys == ["audit"]) and
    (.jobs.audit.if | gsub("\\s+";" ") | sub(" $";"")) ==
      "github.event_name == '\''workflow_dispatch'\'' && github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (inputs.run-audit == true || inputs.run-audit == '\''true'\'')" and
    .jobs.audit.permissions == {contents:"read","id-token":"write"} and .jobs.audit.env == null and
    .jobs.audit["continue-on-error"] == null and
    (.jobs.audit.steps | length == 4) and
    (.jobs.audit.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$")) and
    (.jobs.audit.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
    .jobs.audit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.audit.steps[1].with["persist-credentials"] == false and
    (.jobs.audit.steps[2].uses | test("^octo-sts/action@[0-9a-f]{40}$")) and
    .jobs.audit.steps[2].id == "audit-token" and
    .jobs.audit.steps[2].with == {
      domain:"sts.platform.devantler.tech",
      scope:"devantler-tech",
      identity:"organization-settings-audit"} and
    .jobs.audit.steps[3].run == "bash scripts/check-organization-settings.sh" and
    .jobs.audit.steps[3].env == {GH_TOKEN:"${{ steps.audit-token.outputs.token }}"} and
    all(.jobs.audit.steps[]; .if == null and .["continue-on-error"] == null)
  ' "$1" >/dev/null 2>&1
}
# The policy grants exactly read authority over this repository, to exactly this
# workflow on main.
verify_policy() {
  jq -e '. == {
    issuer:"https://token.actions.githubusercontent.com",
    subject:"repo:devantler-tech/.github:ref:refs/heads/main",
    claim_pattern:{
      repository_owner_id:"178524219",
      job_workflow_ref:"devantler-tech/\\.github/\\.github/workflows/organization-settings-audit\\.yaml@refs/heads/main"},
    repositories:[".github"],
    permissions:{metadata:"read", organization_administration:"read"}}' "$1" >/dev/null 2>&1
}
verify "$work/source.json" || {
  echo 'FAIL: organization audit must use main, opt-in and narrowly scoped read authority' >&2
  exit 1
}
verify_policy "$work/policy.json" || {
  echo 'FAIL: the audit policy must grant only read authority over this repository, to this workflow on main' >&2
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
restored App key	.jobs.audit.steps[2].with["private-key"]="${{ secrets.APP_PRIVATE_KEY }}"
another broker identity	.jobs.audit.steps[2].with.identity="apply-custom-properties"
another broker	.jobs.audit.steps[2].with.domain="sts.example.com"
another scope	.jobs.audit.steps[2].with.scope="devantler-tech/platform"
mutable source	.jobs.audit.steps[1].with.ref="main"
persisted credential	.jobs.audit.steps[1].with["persist-credentials"]=true
replaced token	.jobs.audit.steps[3].env.GH_TOKEN="${{ secrets.APP_PRIVATE_KEY }}"
ignored worker failure	.jobs.audit.steps[3]["continue-on-error"]=true
skipped worker	.jobs.audit.steps[3].if="false"
ambient secret	.env.API_KEY="${{ secrets.APP_PRIVATE_KEY }}"
second writer	.jobs.writer={permissions:{contents:"write"}}
mutable dependency	.jobs.audit.steps[2].uses="octo-sts/action@main"
CASES
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$work/policy.json" >"$work/mutated.json"
  if verify_policy "$work/mutated.json"; then
    echo "FAIL: accepted policy $name" >&2
    exit 1
  fi
  echo "PASS: rejects policy $name"
done <<'CASES'
App write	.permissions.organization_administration="write"
another permission	.permissions.contents="write"
no permissions	del(.permissions)
broad repository scope	del(.repositories)
another repository	.repositories += ["platform"]
another branch	.subject="repo:devantler-tech/.github:ref:refs/heads/other"
another workflow	.claim_pattern.job_workflow_ref="devantler-tech/\\.github/\\.github/workflows/apply-custom-properties\\.yaml@refs/heads/main"
no owner pin	del(.claim_pattern.repository_owner_id)
an App pin	.app="botantler-1"
CASES
echo 'PASS: organization settings audit preserves activation, source and read authority'
