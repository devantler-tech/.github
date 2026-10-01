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
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-deploy-deletions.sh"))] | length == 1) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-")) |
      select(.shell != "bash")] | length == 0)
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
mkdir -p "$work/producer/bin" "$work/producer/candidate" "$work/producer/trusted/scripts"
yq -r '.jobs.metadata-guards.steps[] | select(.name == "🚦 Validate release contract") | .run' "$workflow" >"$work/producer/validate.sh"
cat >"$work/producer/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
command="$3"
if [[ "$command" == "$GIT_FAILURE_INJECT" ]]; then
  echo "injected Git $command failure" >&2
  exit 23
fi
case "$command" in
log) printf 'fix: fixture change\n' ;;
diff) printf 'deploy/fixture.yaml\0' ;;
*) exit 24 ;;
esac
GIT
cat >"$work/producer/trusted/scripts/validate-release-contract.sh" <<'VALIDATOR'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
VALIDATOR
chmod +x "$work/producer/bin/git"
for producer in log diff; do
  if (
    cd "$work/producer"
    export PATH="$work/producer/bin:$PATH" GIT_FAILURE_INJECT="$producer"
    export BASE_SHA=base HEAD_SHA=head PR_TITLE='fix: fixture change' COMMIT_COUNT=2
    if [[ "$(yq -r '.jobs.metadata-guards.steps[] | select(.name == "🚦 Validate release contract") | .shell // ""' "$workflow")" == bash ]]; then
      bash --noprofile --norc -eo pipefail validate.sh
    else
      bash --noprofile --norc -e validate.sh
    fi
  ) >"$work/producer.log" 2>&1; then
    fail "accepted failed Git $producer producer as an empty diff"
    exit 1
  fi
  [[ "$(cat "$work/producer.log")" == *"injected Git $producer failure"* ]] || {
    fail "Git $producer failure fixture did not reach the producer"
    exit 1
  }
done
echo 'ok: actual release step rejects failed Git log and diff producers'
kubectl kustomize "$repo_root/deploy" >"$work/render.yaml"
check_metadata "$workflow" "$work/render.yaml"
bash "$repo_root/tests/deploy-guards-ruleset.sh"
echo 'ok: metadata edits run independently required trusted validators'

for mutation in no-edited skip-guards candidate-validator no-pipefail; do
  case "$mutation" in
  no-edited) expression='.on.pull_request.types -= ["edited"]' ;;
  skip-guards) expression='.jobs.metadata-guards.if = "false"' ;;
  candidate-validator) expression='(.jobs.metadata-guards.steps[] | select(.run // "" | contains("validate-release-contract.sh"))).run |= sub("trusted/scripts/"; "candidate/scripts/")' ;;
  no-pipefail) expression='del(.jobs.metadata-guards.steps[].shell)' ;;
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
echo 'ok: absent edit coverage, skipped guards, candidate validators, unsafe shell and missing enforcement fail'
