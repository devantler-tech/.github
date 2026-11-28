#!/usr/bin/env bash
# The legacy coverage workflow must supply only reviewed complete-census credentials.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/repository-coverage-check.yaml" >"$work/workflow.json"
verify() {
  jq -e '
    def normalized: gsub("\\s+";" ") | sub(" $";"");
    (.on | keys == ["schedule","workflow_dispatch"]) and .permissions == {} and
    (.jobs["repository-coverage-check"].if | normalized) ==
      "github.repository == '\''devantler-tech/.github'\'' && github.ref == '\''refs/heads/main'\'' && (github.event_name == '\''schedule'\'' || github.event_name == '\''workflow_dispatch'\'')" and
    .jobs["repository-coverage-check"].permissions == {contents:"read","id-token":"write"} and
    .jobs["repository-coverage-check"].steps[0].with.ref == "${{ github.workflow_sha }}" and
    .jobs["repository-coverage-check"].steps[0].with["persist-credentials"] == false and
    (.jobs["repository-coverage-check"].steps[1].uses | test("^octo-sts/action@[0-9a-f]{40}$")) and
    .jobs["repository-coverage-check"].steps[1].with == {domain:"sts.platform.devantler.tech",scope:"devantler-tech",identity:"repository-coverage-check"} and
    .jobs["repository-coverage-check"].steps[2].env == {GH_TOKEN:"${{ steps.app-token.outputs.token }}"} and
    .jobs["repository-coverage-check"].steps[2].run == "bash scripts/check-repository-coverage.sh" and
    all(.jobs["repository-coverage-check"].steps[]; .if == null and .["continue-on-error"] == null)
  ' "$1" >/dev/null 2>&1
}
verify "$work/workflow.json" || {
  echo 'FAIL: coverage workflow lost authenticated read scope' >&2
  exit 1
}
while IFS=$'\t' read -r name mutation; do
  jq "$mutation" "$work/workflow.json" >"$work/mutated.json"
  if verify "$work/mutated.json"; then
    echo "FAIL: accepted $name" >&2
    exit 1
  fi
  echo "PASS: rejects $name"
done <<'CASES'
candidate admission	.jobs["repository-coverage-check"].if="true"
mutable source	.jobs["repository-coverage-check"].steps[0].with.ref="main"
persisted token	.jobs["repository-coverage-check"].steps[0].with["persist-credentials"]=true
write App	.jobs["repository-coverage-check"].steps[1].with["permission-administration"]="write"
partial installation	.jobs["repository-coverage-check"].steps[1].with.repositories=".github"
wrong proof identity	.jobs["repository-coverage-check"].steps[2].env.GH_INSTALLATION_ID="1"
missing proof key	.jobs["repository-coverage-check"].steps[2].env.GH_APP_PRIVATE_KEY=""
ignored census	.jobs["repository-coverage-check"].steps[2]["continue-on-error"]=true
CASES
# The census proves completeness only because this token is unscoped: a policy that lists
# repositories would make the installation listing undercount. So the trust policy is pinned exactly.
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
yq -o=json '.' "$root_dir/.github/chainguard/repository-coverage-check.sts.yaml" | jq -e '. == {
  issuer:"https://token.actions.githubusercontent.com", subject:"repo:devantler-tech/.github:ref:refs/heads/main",
  claim_pattern:{repository_owner_id:"178524219",
    job_workflow_ref:"devantler-tech/\\.github/\\.github/workflows/repository-coverage-check\\.yaml@refs/heads/main"},
  permissions:{metadata:"read",organization_administration:"read"}}' >/dev/null || {
  echo 'FAIL: the repository-coverage-check trust policy must stay exactly the reviewed unscoped read-only grant' >&2
  exit 1
}
