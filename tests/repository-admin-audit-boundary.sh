#!/usr/bin/env bash
# The live audit's credential and activation boundary has no PR execution path.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/repository-admin-team-audit.yaml" >"$work/source.json"
verify() {
  jq -e '
    (.on | keys == ["workflow_dispatch"]) and .permissions == {} and
    .on.workflow_dispatch == {} and
    (.jobs | keys == ["audit"]) and
    (.jobs.audit.if | gsub("\\s+";" ") | sub(" $";"")) ==
      "github.event_name == '\''workflow_dispatch'\'' && github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\''" and
    .jobs.audit.permissions == {contents:"read","id-token":"write"} and
    (.jobs.audit.steps | length == 4) and
    (.jobs.audit.steps[0].uses | startswith("step-security/harden-runner@")) and
    .jobs.audit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.audit.steps[1].with["persist-credentials"] == false and
    (.jobs.audit.steps[2].uses | test("^octo-sts/action@[0-9a-f]{40}$")) and
    .jobs.audit.steps[2].with == {domain:"sts.platform.devantler.tech",scope:"devantler-tech",identity:"repository-admin-team-audit"} and
    .jobs.audit.steps[3].run == "bash scripts/check-repository-admin-teams.sh" and
    .jobs.audit.steps[3].env == {GH_TOKEN:"${{ steps.audit-token.outputs.token }}"}
  ' "$1" >/dev/null 2>&1
}
verify "$work/source.json" || { echo 'FAIL: live audit must retain its main-only read-only boundary' >&2; exit 1; }
while IFS=$'\t' read -r label mutation; do
  jq "$mutation" "$work/source.json" >"$work/mutated.json"
  if verify "$work/mutated.json"; then echo "FAIL: $label accepted" >&2; exit 1; fi
  echo "PASS: rejects $label"
done <<'CASES'
retired rollout input	.on.workflow_dispatch.inputs["run-audit"]={type:"boolean",default:false}
PR trigger	.on.pull_request={}
unguarded credentials	.jobs.audit.if="true"
write-scoped workflow token	.jobs.audit.permissions.contents="write"
write-scoped App token	.jobs.audit.steps[2].with["permission-administration"]="write"
partial repository selection	.jobs.audit.steps[2].with.repositories="fixture_public"
partial repository identities	.jobs.audit.steps[2].with.repository_ids="1"
unbound installation proof	.jobs.audit.steps[3].env.GH_INSTALLATION_ID="77"
mutable source checkout	.jobs.audit.steps[1].with.ref="main"
persisted credentials	.jobs.audit.steps[1].with["persist-credentials"]=true
implicit human fallback	.jobs.audit.steps[3].run+=" --organization-admin"
CASES
# The census proves completeness only because this token is unscoped: a policy that lists
# repositories would make the installation listing undercount. So the trust policy is pinned exactly.
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
yq -o=json '.' "$root_dir/.github/chainguard/repository-admin-team-audit.sts.yaml" | jq -e '. == {
  issuer:"https://token.actions.githubusercontent.com", subject:"repo:devantler-tech/.github:ref:refs/heads/main",
  claim_pattern:{repository_owner_id:"178524219",
    job_workflow_ref:"devantler-tech/\\.github/\\.github/workflows/repository-admin-team-audit\\.yaml@refs/heads/main"},
  permissions:{administration:"read",metadata:"read",organization_administration:"read"}}' >/dev/null || {
  echo 'FAIL: the repository-admin-team-audit trust policy must stay exactly the reviewed unscoped read-only grant' >&2
  exit 1
}
echo 'PASS: live admin audit preserves activation, source and credential boundaries'
