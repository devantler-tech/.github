#!/usr/bin/env bash
# Required workflow rules ignore edited; a status check must cover metadata (#250).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "metadata-events: $*" >&2
  return 1
}

check_metadata() {
  local workflow="$1" render="$2" metadata rule
  [[ -f "$workflow" ]] || {
    fail 'metadata workflow is missing'
    return 1
  }
  metadata="$(yq -o=json '.' "$workflow")" || return 1
  jq -e '
    .on.pull_request.types as $events |
    (["opened","synchronize","reopened","edited","ready_for_review"] - $events | length == 0) and
    (.on | has("merge_group") | not) and
    .permissions == {} and
    .jobs["metadata-guards"].name == "PR Metadata Guards" and
    .jobs["metadata-guards"].permissions == {"contents":"read"} and
    (.jobs["metadata-guards"] | has("if") | not) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with["persist-credentials"] != false)] | length == 0) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with.repository == "devantler-tech/.github" and
        .with.ref == "${{ github.event.pull_request.base.sha }}" and .with.path == "trusted")] | length == 1) and
    ([.jobs[].steps[] | select(.run // "" | test("(^|[^/[:alnum:]_])(candidate/)?scripts/"))] | length == 0) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-release-contract.sh"))] | length == 1) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-deploy-deletions.sh"))] | length == 1)
  ' <<<"$metadata" >/dev/null || {
    fail 'metadata must always run both trusted, read-only guards on edits'
    return 1
  }
  rule="$(yq -o=json -I=0 'select(.kind == "OrganizationRuleset" and .metadata.name == "require-dotgithub-pr-metadata")' "$render")" || return 1
  jq -e '
    .spec.managementPolicies == ["Observe","Create","Update","LateInitialize"] and
    .spec.forProvider.target == "branch" and .spec.forProvider.enforcement == "active" and
    .spec.forProvider.conditions == [{"refName":[{"include":["~DEFAULT_BRANCH"],"exclude":[]}],"repositoryId":[933213756]}] and
    (.spec.forProvider.bypassActors // [] | length == 0) and
    .spec.forProvider.rules == [{"requiredStatusChecks":[{"requiredCheck":[{"context":"PR Metadata Guards","integrationId":15368}],"strictRequiredStatusChecksPolicy":false}]}]
  ' <<<"$rule" >/dev/null || {
    fail 'metadata must be a required GitHub Actions status for this repository only'
    return 1
  }
}

workflow="$repo_root/.github/workflows/pr-metadata-guards.yaml"
kubectl kustomize "$repo_root/deploy" >"$work/render.yaml"
check_metadata "$workflow" "$work/render.yaml"
bash "$repo_root/tests/deploy-guards-ruleset.sh"
echo 'ok: metadata edits run independently required trusted validators'

for mutation in no-edited skip-guards candidate-validator; do
  case "$mutation" in
  no-edited) expression='.on.pull_request.types -= ["edited"]' ;;
  skip-guards) expression='.jobs.metadata-guards.if = "false"' ;;
  candidate-validator) expression='(.jobs.metadata-guards.steps[] | select(.run // "" | contains("validate-release-contract.sh"))).run |= sub("trusted/scripts/"; "candidate/scripts/")' ;;
  esac
  yq "$expression" "$workflow" >"$work/mutated.yaml"
  if check_metadata "$work/mutated.yaml" "$work/render.yaml" >"$work/mutation.log" 2>&1; then
    fail "accepted unsafe workflow mutation: $mutation"
    exit 1
  fi
done
yq 'select(.metadata.name != "require-dotgithub-pr-metadata")' "$work/render.yaml" >"$work/no-rule.yaml"
if check_metadata "$workflow" "$work/no-rule.yaml" >"$work/mutation.log" 2>&1; then
  fail 'accepted missing required metadata status'
  exit 1
fi
echo 'ok: absent edit coverage, skipped guards, candidate validators and missing enforcement fail'
