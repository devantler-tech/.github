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

# A draft promotion carries the same source and metadata already checked. Keep
# source/edit triggers and the separate draft-sensitive auto-merge evaluation.
check_promotion_events() {
  local catalogue="$1" auto_merge="$2"
  yq -o=json '.' "$catalogue" | jq -e '
    (.on.pull_request.types | index("ready_for_review") == null) and
    (.on.pull_request.types as $events |
      all(["opened", "synchronize", "reopened", "edited"][];
        . as $event | $events | index($event) != null)) and
    .on.push.branches == ["main"] and (.on | has("merge_group")) and
    ([.jobs[] | .if // empty, .steps[]?.if // empty] |
      all(.[]; test("pull_request\\.draft|event\\.action|ready_for_review") | not))
  ' >/dev/null || {
    fail 'catalogue must check source and edits independently of draft promotion'
    return 1
  }
  yq -o=json '.' "$auto_merge" | jq -e '
    .on.pull_request.types | index("ready_for_review") != null
  ' >/dev/null || {
    fail 'draft-sensitive auto-merge must still evaluate promotion'
    return 1
  }
}

catalogue="$repo_root/.github/workflows/ci.yaml"
auto_merge="$repo_root/.github/workflows/enable-auto-merge.yaml"
check_promotion_events "$catalogue" "$auto_merge"
echo 'ok: catalogue keeps source and edit coverage without a duplicate promotion run'
for mutation in duplicate-promotion no-opened no-synchronize no-reopened no-edited draft-sensitive; do
  case "$mutation" in
    duplicate-promotion) expression='.on.pull_request.types += ["ready_for_review"]' ;;
    no-*) event="${mutation#no-}"; expression=".on.pull_request.types -= [\"$event\"]" ;;
    draft-sensitive) expression='.jobs.test-validate-retired-repo-links.if = "github.event.pull_request.draft == false"' ;;
  esac
  yq "$expression" "$catalogue" >"$work/catalogue-mutated.yaml"
  if check_promotion_events "$work/catalogue-mutated.yaml" "$auto_merge" >"$work/promotion.log" 2>&1; then
    fail "accepted a promotion coverage regression: $mutation"
    exit 1
  fi
done
yq '.on.pull_request.types -= ["ready_for_review"]' "$auto_merge" >"$work/auto-merge-mutated.yaml"
if check_promotion_events "$catalogue" "$work/auto-merge-mutated.yaml" >"$work/promotion.log" 2>&1; then
  fail 'accepted disabled auto-merge promotion evaluation'
  exit 1
fi
echo 'ok: duplicate promotion, missing source/edit coverage, draft-sensitive catalogue and absent auto-merge promotion fail'

check_metadata() {
  local workflow="$1" render="$2" metadata
  [[ -f "$workflow" ]] || {
    fail 'metadata workflow is missing'
    return 1
  }
  metadata="$(yq -o=json '.' "$workflow")" || return 1
  jq -e '
    .on.workflow_dispatch.inputs["pull-request"].required == true and
    (.on | has("pull_request_target") | not) and
    (.on | has("pull_request") | not) and
    (.on | has("merge_group") | not) and
    .permissions == {} and
    .jobs["metadata-guards"].name == "PR Metadata Guards" and
    .jobs["metadata-guards"].permissions == {"contents":"read", "pull-requests":"read"} and
    (.jobs["metadata-guards"] | has("if") | not) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with["persist-credentials"] != false)] | length == 0) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) |
      select(.with.repository == "devantler-tech/.github" and
        .with.ref == "${{ github.workflow_sha }}" and .with.path == "trusted")] | length == 1) and
    ([.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@"))] | length == 1) and
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
    if [[ "$(yq -r '.jobs.metadata-guards.steps[] | select(.name == "🚦 Validate release contract") | .shell // ""' "$workflow")" == bash ]]; then
      env PATH="$work/producer/bin:$PATH" GIT_FAILURE_INJECT="$producer" BASE_SHA=base HEAD_SHA=head PR_TITLE_JSON='"fix: fixture change"' COMMIT_COUNT=2 bash --noprofile --norc -eo pipefail validate.sh
    else
      env PATH="$work/producer/bin:$PATH" GIT_FAILURE_INJECT="$producer" BASE_SHA=base HEAD_SHA=head PR_TITLE_JSON='"fix: fixture change"' COMMIT_COUNT=2 bash --noprofile --norc -e validate.sh
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
mkdir -p "$work/history/trusted/deploy" "$work/history/trusted/scripts"
cp "$repo_root/scripts/validate-release-contract.sh" "$work/history/trusted/scripts/"
cp "$work/producer/validate.sh" "$work/history/validate.sh"
git -C "$work/history/trusted" init -q
git -C "$work/history/trusted" config user.name Fixture
git -C "$work/history/trusted" config user.email fixture@example.invalid
git -C "$work/history/trusted" config commit.gpgsign false
printf 'base\n' >"$work/history/trusted/deploy/fixture.yaml"
git -C "$work/history/trusted" add deploy/fixture.yaml
git -C "$work/history/trusted" commit -qm 'chore: base fixture'
base_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
printf 'changed\n' >"$work/history/trusted/deploy/fixture.yaml"
git -C "$work/history/trusted" add deploy/fixture.yaml
git -C "$work/history/trusted" commit -qm 'docs: candidate attempts to bypass validation'
head_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
mkdir -p "$work/history/candidate/scripts"
printf '#!/usr/bin/env bash\ntouch ../candidate-executed\nexit 0\n' >"$work/history/candidate/scripts/validate-release-contract.sh"
run_history() (
  cd "$work/history"
  env BASE_SHA="$base_sha" HEAD_SHA="$head_sha" PR_TITLE_JSON="$(jq -nc --arg title "$1" '$title')" COMMIT_COUNT="$2" bash --noprofile --norc -eo pipefail validate.sh
)
if run_history 'fix: fixture deploy' 1 >"$work/history.log" 2>&1; then
  fail 'accepted a non-releasing single commit merely because the title releases'
  exit 1
fi
git -C "$work/history/trusted" commit --allow-empty -qm 'docs: second fixture commit'
head_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
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

# Main-only deployments must not be mistaken for this PR's changes/deletions.
cat >"$work/history/trusted/deploy/kustomization.yaml" <<'KUSTOMIZATION'
resources:
  - guard.yaml
KUSTOMIZATION
cat >"$work/history/trusted/deploy/guard.yaml" <<'RESOURCE'
apiVersion: v1
kind: ConfigMap
metadata:
  name: retained
RESOURCE
git -C "$work/history/trusted" add deploy/kustomization.yaml deploy/guard.yaml
git -C "$work/history/trusted" commit -qm 'fix: baseline rendered resource'
shared_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
printf 'Documentation only\n' >"$work/history/trusted/README.md"
git -C "$work/history/trusted" add README.md
git -C "$work/history/trusted" commit -qm 'docs: unrelated PR'
head_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
git -C "$work/history/trusted" checkout -q --detach "$shared_sha"
cp "$work/history/trusted/deploy/guard.yaml" "$work/history/trusted/deploy/main-only.yaml"
yq -i '.metadata.name = "main-only"' "$work/history/trusted/deploy/main-only.yaml"
yq -i '.resources += ["main-only.yaml"]' "$work/history/trusted/deploy/kustomization.yaml"
git -C "$work/history/trusted" add deploy/kustomization.yaml deploy/main-only.yaml
git -C "$work/history/trusted" commit -qm 'fix: main-only deployment'
base_sha="$(git -C "$work/history/trusted" rev-parse HEAD)"
run_history 'docs: unrelated PR' 1 >"$work/history.log" 2>&1 || fail 'main-only deployment was treated as a PR release change'
mkdir "$work/history/temp"
git -C "$work/history/trusted" archive "$head_sha" deploy | tar -x -C "$work/history/candidate"
cp "$repo_root/scripts/validate-deploy-deletions.sh" "$work/history/trusted/scripts/"
: >"$work/history/temp/pr-body.txt"
yq -r '.jobs.metadata-guards.steps[] | select(.name == "🗑️ Validate deploy/ deletions are acknowledged") | .run' "$workflow" >"$work/history/deletions.sh"
(
  cd "$work/history"
  env BASE_SHA="$base_sha" HEAD_SHA="$head_sha" RUNNER_TEMP="$work/history/temp" bash -eo pipefail deletions.sh
) >"$work/history.log" 2>&1 || fail 'main-only resource was treated as a PR deletion'
echo 'ok: diverged main-only deploy changes do not require a release title or deletion acknowledgement'

mkdir -p "$work/api/bin" "$work/api/temp"
yq -r '.jobs.metadata-guards.steps[] | select(.id == "pr") | .run' "$workflow" >"$work/api/read.sh"
yq -r '.jobs.metadata-guards.steps[] | select(.name == "🔎 Refuse changed metadata") | .run' "$workflow" >"$work/api/recheck.sh"
cat >"$work/api/bin/gh" <<'API'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$API_CALLS"
[[ "$*" == 'api --hostname github.com repos/devantler-tech/.github/pulls/354' ]] || exit 24
[[ "$API_CASE" != failure ]] || { printf '{"state":"open"}'; exit 23; }
cat "$API_FIXTURE"
API
chmod +x "$work/api/bin/gh"
jq -n --arg sha "$head_sha" --arg base "$base_sha" '{
  number:354,state:"open",title:"fix: fixture\nhead=attacker",body:"body\nhead=attacker",
  commits:2,updated_at:"2026-10-03T00:00:00Z",
  head:{sha:$sha,repo:{full_name:"devantler-tech/.github"}},
  base:{sha:$base,ref:"main",repo:{full_name:"devantler-tech/.github"}}
}' >"$work/api/healthy.json"
run_api() (
  cd "$work/api"
  env PATH="$work/api/bin:$PATH" API_CASE="$1" API_FIXTURE="$2" API_CALLS="$work/api/calls" \
    RUNNER_TEMP="$work/api/temp" GITHUB_OUTPUT="$work/api/output" \
    PR_NUMBER="${3:-354}" WORKFLOW_REF="${4:-refs/heads/main}" \
    bash --noprofile --norc -eo pipefail "$5"
)
: >"$work/api/output"
run_api healthy "$work/api/healthy.json" 354 refs/heads/main read.sh
[[ "$(wc -l <"$work/api/output" | tr -d ' ')" == 4 ]] || fail 'metadata injected an output line'
run_api healthy "$work/api/healthy.json" 354 refs/heads/main recheck.sh
for case_name in failure closed fork malformed-sha missing-commits; do
  case "$case_name" in
    closed) change='.state = "closed"' ;;
    fork) change='.head.repo.full_name = "other/fork"' ;;
    malformed-sha) change='.head.sha = "main"' ;;
    missing-commits) change='del(.commits)' ;;
    *) change='.' ;;
  esac
  jq "$change" "$work/api/healthy.json" >"$work/api/case.json"
  if run_api "$case_name" "$work/api/case.json" 354 refs/heads/main read.sh >"$work/api.log" 2>&1; then
    fail "accepted incomplete or unsupported PR metadata: $case_name"
    exit 1
  fi
done
for field in head.sha base.sha title body commits updated_at state; do
  jq --arg field "$field" 'setpath($field | split("."); "changed")' "$work/api/healthy.json" >"$work/api/changed.json"
  if run_api healthy "$work/api/changed.json" 354 refs/heads/main recheck.sh >"$work/api.log" 2>&1; then
    fail "accepted metadata that changed during validation: $field"
    exit 1
  fi
done
for invalid in bad-number wrong-ref; do
  : >"$work/api/calls"
  if [[ "$invalid" == bad-number ]]; then
    pr_number=../354
    workflow_ref=refs/heads/main
  else
    pr_number=354
    workflow_ref=refs/heads/candidate
  fi
  if run_api healthy "$work/api/healthy.json" "$pr_number" "$workflow_ref" read.sh >"$work/api.log" 2>&1; then
    fail "accepted dispatch admission: $invalid"
    exit 1
  fi
  [[ ! -s "$work/api/calls" ]] || fail 'invalid dispatch made an API request'
done
echo 'ok: current PR API rejects partial reads, malformed or unsupported PRs, stale metadata and invalid dispatches'
kubectl kustomize "$repo_root/deploy" >"$work/render.yaml"
check_metadata "$workflow" "$work/render.yaml"
bash "$repo_root/tests/deploy-guards-ruleset.sh"
echo 'ok: manual metadata checks use trusted feedback while full CI protection remains'

for mutation in no-dispatch candidate-workflow skip-guards candidate-validator no-pipefail unsafe-checkout; do
  case "$mutation" in
    no-dispatch) expression='del(.on.workflow_dispatch)' ;;
    candidate-workflow) expression='.on.pull_request = {} | del(.on.workflow_dispatch)' ;;
    skip-guards) expression='.jobs.metadata-guards.if = "false"' ;;
    candidate-validator) expression='(.jobs.metadata-guards.steps[] | select(.run // "" | contains("validate-release-contract.sh"))).run |= sub("trusted/scripts/"; "candidate/scripts/")' ;;
    no-pipefail) expression='del(.jobs.metadata-guards.steps[].shell)' ;;
    unsafe-checkout) expression='(.jobs.metadata-guards.steps[] | select(.with.path == "trusted")).with.allow-unsafe-pr-checkout = true' ;;
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
echo 'ok: untrusted workflow source, absent manual entry, unsafe checkout, skipped guards, candidate validators and premature enforcement fail'
