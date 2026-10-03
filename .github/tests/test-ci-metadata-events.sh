#!/usr/bin/env bash
# Reviewed metadata feedback is staged without claiming required enforcement (#250).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "metadata-events: $*" >&2
  return 1
}

check_metadata() {
  local workflow="$1" render="$2" metadata
  [[ -f "$workflow" ]] || {
    fail 'metadata workflow is missing'
    return 1
  }
  metadata="$(yq -o=json '.' "$workflow")" || return 1
  jq -e '
    (.on.pull_request_target.types // []) as $events |
    (["opened","synchronize","reopened","edited","ready_for_review"] - $events | length == 0) and
    (.on | has("pull_request") | not) and
    (.on | has("merge_group") | not) and
    .permissions == {} and
    .jobs["metadata-guards"].name == "PR Metadata Guards" and
    .jobs["metadata-guards"].permissions == {"contents":"read"} and
    (.jobs["metadata-guards"] | has("if") | not) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with["persist-credentials"] != false)] | length == 0) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with.repository == "devantler-tech/.github" and
        .with.ref == "${{ github.workflow_sha }}" and .with.path == "trusted")] | length == 1) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with.path == "candidate" and .with.repository == "devantler-tech/.github" and
        .with.ref == "${{ github.event.pull_request.head.sha }}")] | length == 1) and
    ([.jobs[].steps[] | select(.with["allow-unsafe-pr-checkout"] // false)] | length == 0) and
    ([.jobs[].steps[] | select(tojson | test("secrets\\."; "i"))] | length == 0) and
    ([.jobs[].steps[] | select(.run // "" | test("(^|[^/[:alnum:]_])(candidate/)?scripts/"))] | length == 0) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-release-contract.sh"))] | length == 1) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-deploy-deletions.sh"))] | length == 1) and
    ([.jobs[].steps[] | select(.run // "" | contains("bash trusted/scripts/validate-")) |
      select(.shell != "bash")] | length == 0)
  ' <<<"$metadata" >/dev/null || {
    fail 'metadata feedback must use reviewed workflow source and read-only candidate data on edits'
    return 1
  }
  if yq -o=json -I=0 'select(.kind == "OrganizationRuleset")' "$render" |
    jq -s -e 'any(.[]; any(.spec.forProvider.rules[]?; any(.requiredStatusChecks[]?.requiredCheck[]?; .context == "PR Metadata Guards")))' >/dev/null; then
    fail 'feedback cannot become a required status before head attribution and spoofing controls are proven'
    return 1
  fi
  yq -o=json '.' "$repo_root/.github/workflows/ci.yaml" |
    jq -e '.on.pull_request.types | index("edited") != null' >/dev/null || {
    fail 'full CI must retain edit protection until an independent trusted gate is proven'
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
    if [[ "$(yq -r '.jobs.metadata-guards.steps[] | select(.name == "🚦 Validate release contract") | .shell // ""' "$workflow")" == bash ]]; then
      env BASE_SHA=base HEAD_SHA=head PR_TITLE='fix: fixture change' COMMIT_COUNT=2 bash --noprofile --norc -eo pipefail validate.sh
    else
      env BASE_SHA=base HEAD_SHA=head PR_TITLE='fix: fixture change' COMMIT_COUNT=2 bash --noprofile --norc -e validate.sh
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

# Run the actual workflow step against Git history and the reviewed validator.
# Candidate scripts are hostile data: neither a valid nor invalid title may run them.
mkdir -p "$work/history/candidate/deploy" "$work/history/trusted/scripts"
cp "$repo_root/scripts/validate-release-contract.sh" "$work/history/trusted/scripts/"
cp "$work/producer/validate.sh" "$work/history/validate.sh"
git -C "$work/history/candidate" init -q
git -C "$work/history/candidate" config user.name Fixture
git -C "$work/history/candidate" config user.email fixture@example.invalid
git -C "$work/history/candidate" config commit.gpgsign false
printf 'base\n' >"$work/history/candidate/deploy/fixture.yaml"
git -C "$work/history/candidate" add deploy/fixture.yaml
git -C "$work/history/candidate" commit -qm 'chore: base fixture'
base_sha="$(git -C "$work/history/candidate" rev-parse HEAD)"
printf 'changed\n' >"$work/history/candidate/deploy/fixture.yaml"
mkdir -p "$work/history/candidate/scripts"
printf '#!/usr/bin/env bash\ntouch ../candidate-executed\nexit 0\n' >"$work/history/candidate/scripts/validate-release-contract.sh"
git -C "$work/history/candidate" add deploy/fixture.yaml scripts/validate-release-contract.sh
git -C "$work/history/candidate" commit -qm 'docs: candidate attempts to bypass validation'
head_sha="$(git -C "$work/history/candidate" rev-parse HEAD)"
run_history() (
  cd "$work/history"
  env BASE_SHA="$base_sha" HEAD_SHA="$head_sha" PR_TITLE="$1" COMMIT_COUNT="$2" bash --noprofile --norc -eo pipefail validate.sh
)
if run_history 'fix: fixture deploy' 1 >"$work/history.log" 2>&1; then
  fail 'accepted a non-releasing single commit merely because the title releases'
  exit 1
fi
git -C "$work/history/candidate" commit --allow-empty -qm 'docs: second fixture commit'
head_sha="$(git -C "$work/history/candidate" rev-parse HEAD)"
run_history 'fix: fixture deploy' 2 >"$work/history.log" 2>&1
if run_history 'docs: fixture deploy' 2 >"$work/history.log" 2>&1; then
  fail 'accepted an edited non-releasing title for a deploy change'
  exit 1
fi
[[ ! -e "$work/history/candidate-executed" ]] || {
  fail 'executed candidate-controlled validator'
  exit 1
}
echo 'ok: reviewed validator accepts healthy Git history, rejects bad edits and ignores hostile candidate scripts'
kubectl kustomize "$repo_root/deploy" >"$work/render.yaml"
check_metadata "$workflow" "$work/render.yaml"
bash "$repo_root/tests/deploy-guards-ruleset.sh"
echo 'ok: metadata edits use trusted feedback while full CI protection remains'

for mutation in no-edited candidate-workflow skip-guards candidate-validator no-pipefail unsafe-checkout; do
  case "$mutation" in
  no-edited) expression='.on.pull_request_target.types -= ["edited"]' ;;
  candidate-workflow) expression='.on.pull_request = .on.pull_request_target | del(.on.pull_request_target)' ;;
  skip-guards) expression='.jobs.metadata-guards.if = "false"' ;;
  candidate-validator) expression='(.jobs.metadata-guards.steps[] | select(.run // "" | contains("validate-release-contract.sh"))).run |= sub("trusted/scripts/"; "candidate/scripts/")' ;;
  no-pipefail) expression='del(.jobs.metadata-guards.steps[].shell)' ;;
  unsafe-checkout) expression='(.jobs.metadata-guards.steps[] | select(.with.path == "candidate")).with.allow-unsafe-pr-checkout = true' ;;
  esac
  yq "$expression" "$workflow" >"$work/mutated.yaml"
  if check_metadata "$work/mutated.yaml" "$work/render.yaml" >"$work/mutation.log" 2>&1; then
    fail "accepted unsafe workflow mutation: $mutation"
    exit 1
  fi
done
cat "$work/render.yaml" >"$work/unsafe-rule.yaml"
cat >>"$work/unsafe-rule.yaml" <<'RULE'
---
apiVersion: enterprise.github.m.upbound.io/v1alpha1
kind: OrganizationRuleset
metadata:
  name: unsafe-metadata-feedback
spec:
  forProvider:
    rules:
      - requiredStatusChecks:
          - requiredCheck:
              - context: PR Metadata Guards
RULE
if check_metadata "$workflow" "$work/unsafe-rule.yaml" >"$work/mutation.log" 2>&1; then
  fail 'accepted an unproven required feedback status'
  exit 1
fi
echo 'ok: untrusted workflow source, absent edit coverage, unsafe checkout, skipped guards, candidate validators and premature enforcement fail'
