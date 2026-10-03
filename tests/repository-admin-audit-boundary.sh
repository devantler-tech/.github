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
    .on.workflow_dispatch.inputs["run-audit"].type == "boolean" and
    .on.workflow_dispatch.inputs["run-audit"].default == false and
    (.jobs | keys == ["audit"]) and
    (.jobs.audit.if | gsub("\\s+";" ") | sub(" $";"")) ==
      "github.event_name == '\''workflow_dispatch'\'' && github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (inputs.run-audit == true || inputs.run-audit == '\''true'\'')" and
    .jobs.audit.permissions == {contents:"read"} and
    (.jobs.audit.steps | length == 4) and
    (.jobs.audit.steps[0].uses | startswith("step-security/harden-runner@")) and
    .jobs.audit.steps[1].with.ref == "${{ github.workflow_sha }}" and
    .jobs.audit.steps[1].with["persist-credentials"] == false and
    .jobs.audit.steps[2].with == {
      "client-id":"${{ vars.APP_CLIENT_ID }}",
      "private-key":"${{ secrets.APP_PRIVATE_KEY }}",
      owner:"devantler-tech",
      "permission-metadata":"read",
      "permission-administration":"read"} and
    .jobs.audit.steps[3].run == "bash scripts/check-repository-admin-teams.sh" and
    .jobs.audit.steps[3].env == {
      GH_TOKEN:"${{ steps.audit-token.outputs.token }}",
      GH_INSTALLATION_ID:"${{ steps.audit-token.outputs.installation-id }}",
      GH_APP_CLIENT_ID:"${{ vars.APP_CLIENT_ID }}",
      GH_APP_PRIVATE_KEY:"${{ secrets.APP_PRIVATE_KEY }}"}
  ' "$1" >/dev/null 2>&1
}
verify "$work/source.json" || { echo 'FAIL: live audit must retain its default-off main-only read-only boundary' >&2; exit 1; }
while IFS=$'\t' read -r label mutation; do
  jq "$mutation" "$work/source.json" >"$work/mutated.json"
  if verify "$work/mutated.json"; then echo "FAIL: $label accepted" >&2; exit 1; fi
  echo "PASS: rejects $label"
done <<'CASES'
default activation	.on.workflow_dispatch.inputs["run-audit"].default=true
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
echo 'PASS: live admin audit preserves activation, source and credential boundaries'
