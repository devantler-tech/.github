#!/usr/bin/env bash

set -euo pipefail

# Keep the retired singleton association inert while preserving the product-owned
# validator's trust, identity and failure controls. Shared admission and its
# executed result binding are pinned by repository-admission-ruleset.sh.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${DEPLOY_GUARDS_WORKFLOW:-${repo_root}/.github/workflows/deploy-guards.yaml}"
action="${DEPLOY_GUARDS_ACTION:-${repo_root}/.github/actions/pr-admission/action.yaml}"
render="$(mktemp)"
scratch="$(mktemp -d)"
trap 'rm -f "${render}"; rm -rf "$scratch"' EXIT

fail() {
  echo "deploy-guards-ruleset test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "${tool}" >/dev/null || fail "required tool '${tool}' not found"
done

kubectl kustomize "${repo_root}/deploy" >"${render}" ||
  fail "kubectl kustomize deploy/ failed"

selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-dotgithub-deploy-guards")'
count="$(yq -N "${selector} | .metadata.name" "${render}" | grep -c . || true)"
[[ "${count}" == "1" ]] || fail "expected exactly one rendered deploy-guards ruleset, got ${count}"

assert_value() {
  local label="$1" expected="$2" expression="$3" actual
  actual="$(yq -r "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_json() {
  local label="$1" expected="$2" expression="$3" actual
  actual="$(yq -o=json -I=0 "${selector} | ${expression}" "${render}")"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

# 933213756 is devantler-tech/.github: preserve the retired record's exact scope.
assert_value "ruleset name" "Require workflow - .github deploy guards" '.spec.forProvider.name'
assert_value "ruleset target" "branch" '.spec.forProvider.target'
assert_value "ruleset enforcement" "disabled" '.spec.forProvider.enforcement'
assert_json "management policy" '["Observe","Create","Update","LateInitialize"]' '.spec.managementPolicies'
assert_json "target repository" '[933213756]' '.spec.forProvider.conditions[0].repositoryId'
assert_json "target branch" '["~DEFAULT_BRANCH"]' '.spec.forProvider.conditions[0].refName[0].include'
assert_json "target exclusions" '[]' '.spec.forProvider.conditions[0].refName[0].exclude'
assert_value "bypass actor count" "0" '(.spec.forProvider.bypassActors // []) | length'
assert_value "rule count" "1" '.spec.forProvider.rules | length'
assert_json "inert retired rule" '[{"creation":false,"deletion":false,"nonFastForward":false,"requiredLinearHistory":false,"requiredSignatures":false,"update":false}]' '.spec.forProvider.rules'

[[ -f "${workflow}" ]] || fail "required workflow ${workflow#"${repo_root}"/} does not exist"
[[ -f "$action" ]] || fail 'repository-owned admission action is missing'

# Read a field from the required workflow source under test.
wf() { yq -r "$1" "${workflow}"; }
# Read a field from the product-owned composite action under test.
ac() { yq -r "$1" "$action"; }

# Check the actual action interface and every GitHub-to-validator identity bind.
check_action_boundary() {
  yq -o=json '.' "$1" | jq -e '
    .author == "devantler-tech" and
    (.inputs | keys) == ["candidate-sha"] and
    .inputs["candidate-sha"].required == true and
    .runs.using == "composite" and (.runs.steps | length) == 4 and
    all(.runs.steps[]; .if == null and (.["continue-on-error"] // false) == false and
      (if has("run") then .shell == "bash" else true end)) and
    .runs.steps[0].env == {
      EVENT_NAME:"${{ github.event_name }}",CANDIDATE_SHA:"${{ inputs.candidate-sha }}",
      BASE_SHA:"${{ github.event.pull_request.base.sha }}",
      HEAD_SHA:"${{ github.event.pull_request.head.sha }}",
      COMMIT_COUNT:"${{ github.event.pull_request.commits }}"
    } and
    .runs.steps[1].id == "data" and
    .runs.steps[1].uses == null and
    .runs.steps[1].run == "bash \"$TRUSTED_ROOT/.github/scripts/prepare-deploy-admission-data.sh\"" and
    .runs.steps[1].env == {
      TRUSTED_ROOT:"${{ github.action_path }}/../../..",
      BASE_SHA:"${{ github.event.pull_request.base.sha }}",
      HEAD_SHA:"${{ github.event.pull_request.head.sha }}",
      CANDIDATE_SHA:"${{ inputs.candidate-sha }}"
    } and
    .runs.steps[2].env == {
      TRUSTED_ROOT:"${{ github.action_path }}/../../..",
      BASE_SHA:"${{ github.event.pull_request.base.sha }}",
      HEAD_SHA:"${{ github.event.pull_request.head.sha }}",
      PR_TITLE:"${{ github.event.pull_request.title }}",
      COMMIT_COUNT:"${{ github.event.pull_request.commits }}",
      ADMISSION_HISTORY:"${{ steps.data.outputs.history }}"
    } and
    .runs.steps[3].env == {
      TRUSTED_ROOT:"${{ github.action_path }}/../../..",
      PR_BODY:"${{ github.event.pull_request.body }}",
      BASE_DEPLOY:"${{ steps.data.outputs.base-deploy }}",
      CANDIDATE_DEPLOY:"${{ steps.data.outputs.candidate-deploy }}"
    }
  ' >/dev/null
}
check_action_boundary "$action" || fail 'product action loses an immutable identity or execution boundary'
# shellcheck disable=SC2016 # These are literal GitHub-expression mutation controls.
for mutation in \
  'del(.author)' \
  '.runs.steps[0].if = "false"' \
  '.runs.steps[0]["continue-on-error"] = true' \
  '.runs.steps[0].env.CANDIDATE_SHA = "main"' \
  '.runs.steps[0].env.COMMIT_COUNT = "1"' \
  '.runs.steps[1].env.CANDIDATE_SHA = "main"' \
  '.runs.steps[1].env.TRUSTED_ROOT = "candidate"' \
  '.runs.steps[1].uses = "actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  '.runs.steps[1].run = "true"' \
  '.runs.steps[2].env.BASE_SHA = "${{ github.sha }}"' \
  '.runs.steps[2].env.PR_TITLE = "fix: bypass"' \
  '.runs.steps[2].env.TRUSTED_ROOT = "candidate"' \
  '.runs.steps[2].shell = "sh"' \
  '.runs.steps[2].if = "false"' \
  '.runs.steps[3].env.PR_BODY = ""' \
  '.runs.steps[3].env.CANDIDATE_DEPLOY = "candidate/deploy"' \
  '.runs.steps[3]["continue-on-error"] = true'; do
  yq "$mutation" "$action" >"$scratch/unsafe-action.yaml"
  if check_action_boundary "$scratch/unsafe-action.yaml"; then
    fail "unsafe action mutation was accepted: $mutation"
  fi
done

# Execute the action's real precondition, including merge-group and missing-data refusals.
ac '.runs.steps[0].run' >"$scratch/metadata.sh"
for metadata_case in valid merge-group missing-candidate mutable-base missing-head zero-commits text-commits; do
  event=pull_request candidate=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb head=cccccccccccccccccccccccccccccccccccccccc commits=2
  case "$metadata_case" in
  merge-group) event=merge_group ;;
  missing-candidate) candidate='' ;;
  mutable-base) base=main ;;
  missing-head) head='' ;;
  zero-commits) commits=0 ;;
  text-commits) commits=two ;;
  esac
  status=0
  env -i PATH="$PATH" EVENT_NAME="$event" CANDIDATE_SHA="$candidate" BASE_SHA="$base" \
    HEAD_SHA="$head" COMMIT_COUNT="$commits" bash --noprofile --norc -e -o pipefail \
    "$scratch/metadata.sh" >"$scratch/metadata.log" 2>&1 || status=$?
  if [[ "$metadata_case" == valid ]]; then
    [[ "$status" == 0 ]] || fail 'complete GitHub metadata was refused'
  else
    [[ "$status" != 0 ]] || fail "$metadata_case bypassed the real metadata guard"
    grep -q 'requires complete pull-request metadata' "$scratch/metadata.log" || fail "$metadata_case failed for an unrelated reason"
  fi
done

# The compatibility wrapper must invoke the action unconditionally, not repaint a failure green.
yq -o=json '.' "$workflow" | jq -e '
  .jobs["deploy-guards"].if == null and
  (.jobs["deploy-guards"].steps | length) == 3 and
  all(.jobs["deploy-guards"].steps[]; .if == null and (.["continue-on-error"] // false) == false) and
  .jobs["deploy-guards"].steps[-1].with == {"candidate-sha":"${{ github.sha }}"}
' >/dev/null || fail 'the compatibility wrapper skips or masks product admission'

[[ "$(wf '.on | has("pull_request")')" == "true" ]] || fail "workflow must run on pull_request"
# A merge-group event carries no pull-request title, commits or body, so a
# merge_group run could only skip both guards and pass. Leaving the trigger out
# makes a merge queue wait on this required check instead.
[[ "$(wf '.on | has("merge_group")')" == "false" ]] || fail "workflow must not run on merge_group, where both guards would be skipped"
guarded_steps="$(ac '[.runs.steps[] | select(.run // "" | test("validate-(release-contract|deploy-deletions)\\.sh")) | select(.if == null and (.["continue-on-error"] // false) == false)] | length')"
[[ "${guarded_steps}" == "2" ]] || fail "both validator steps must run on pull_request, got ${guarded_steps}"
[[ "$(wf '.permissions | tojson')" == "{}" ]] || fail "workflow-level permissions must be {}"
# shellcheck disable=SC2016 # GitHub expressions are literal wiring expectations.
[[ "$(wf '.jobs["deploy-guards"].steps[-1].uses')" == './trusted/.github/actions/pr-admission' &&
"$(wf '.jobs["deploy-guards"].steps[-1].with."candidate-sha"')" == '${{ github.sha }}' ]] ||
  fail 'the reviewed local action must receive only GitHub-supplied candidate identity'
yq -o=json '.jobs["deploy-guards"].permissions' "$workflow" | jq -e '. == {contents:"read"}' >/dev/null || fail 'admission must remain read-only'
[[ "$(ac '.runs.using')" == composite && "$(ac '.inputs."candidate-sha".required')" == true ]] || fail 'local action interface is missing'
jq -e '. == {version:1,"timeout-minutes":10}' "$repo_root/.github/pr-admission.json" >/dev/null || fail 'product budget changed'
[[ "$(wf '.jobs["deploy-guards"]."timeout-minutes"')" == 10 ]] || fail 'native timeout must preserve the product budget'

# The validators must come from the ruleset-selected source revision. A
# candidate cannot change github.workflow_sha, so this checkout is the trusted one.
# shellcheck disable=SC2016
trusted_checkouts="$(wf '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with.repository == "devantler-tech/.github" and .with.ref == "${{ github.workflow_sha }}" and .with.path == "trusted")] | length')"
[[ "${trusted_checkouts}" == "1" ]] || fail "expected one checkout of the workflow source revision into trusted/, got ${trusted_checkouts}"

unsafe_checkouts="$(wf '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with["persist-credentials"] != false)] | length')"
[[ "${unsafe_checkouts}" == "0" ]] || fail "every checkout must set persist-credentials: false (${unsafe_checkouts} do not)"
[[ "$(ac '[.runs.steps[] | select(.uses // "" | test("^actions/checkout@"))] | length')" == 0 ]] || fail 'product admission must never check out the candidate implementation'

for validator in validate-release-contract.sh validate-deploy-deletions.sh; do
  runs="$(ac "[.runs.steps[] | select(.run // \"\" | contains(\"${validator}\"))] | length")"
  [[ "${runs}" == "1" ]] || fail "expected exactly one step running ${validator}, got ${runs}"
  trusted="$(yq -o=json '.' "$action" | jq --arg validator "$validator" '[.runs.steps[] |
    select((.run // "") | contains("$TRUSTED_ROOT/scripts/" + $validator)) |
    select(.env.TRUSTED_ROOT == "${{ github.action_path }}/../../.." and .shell == "bash")] | length')"
  [[ "${trusted}" == "1" ]] || fail "${validator} must run from trusted/scripts, not the candidate checkout"
done

candidate_scripts="$(ac '[.runs.steps[] | select(.run // "" | test("(^|[^/[:alnum:]_])(candidate/)?scripts/"))] | length')"
[[ "${candidate_scripts}" == "0" ]] || fail "no step may run a script outside trusted/ (${candidate_scripts} do)"

# Execute the actual required step using its declared runner shell. A failed
# producer must not turn into a healthy empty/partial history or diff.
mkdir -p "$scratch/bin" "$scratch/trusted/scripts"
cp "$repo_root/scripts/validate-release-contract.sh" "$scratch/trusted/scripts/"
ac '.runs.steps[] | select(.name == "🚦 Validate release contract") | .run' >"$scratch/step.sh"
case "$(ac '.runs.steps[] | select(.name == "🚦 Validate release contract") | .shell // ""')" in
'') runner_flags=(-e) ;;
bash) runner_flags=(--noprofile --norc -e -o pipefail) ;;
*) fail 'release step has unsupported runner shell' ;;
esac
cat >"$scratch/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "--git-dir=$ADMISSION_HISTORY" ]] || exit 92
shift
case "$1" in
  log)
    printf 'log\n' >>"$TRACE"
    if [[ "$MODE" == log-empty ]]; then echo 'injected Git log failure' >&2; exit 71; fi
    printf 'fix: healthy candidate\n'
    if [[ "$MODE" == log-partial ]]; then echo 'injected Git log failure' >&2; exit 71; fi
    ;;
  diff)
    printf 'diff\n' >>"$TRACE"
    if [[ "$MODE" == diff-empty ]]; then echo 'injected Git diff failure' >&2; exit 72; fi
    if [[ "$MODE" == healthy-other ]]; then printf 'README.md\0'; else printf 'deploy/resource.yaml\0'; fi
    if [[ "$MODE" == diff-partial ]]; then echo 'injected Git diff failure' >&2; exit 72; fi
    ;;
  *) exit 93 ;;
esac
GIT
chmod +x "$scratch/bin/git"
for mode in healthy-deploy healthy-other log-empty log-partial diff-empty diff-partial; do
  : >"$scratch/trace"
  status=0
  (cd "$scratch" && env -i PATH="$scratch/bin:$PATH" MODE="$mode" TRACE="$scratch/trace" \
    BASE_SHA=base HEAD_SHA=head ADMISSION_HISTORY="$scratch/history.git" TRUSTED_ROOT="$scratch/trusted" PR_TITLE='fix: preserve required guard failures' COMMIT_COUNT=2 \
    bash "${runner_flags[@]}" step.sh) >"$scratch/result" 2>&1 || status=$?
  if [[ "$mode" == healthy-* ]]; then
    [[ "$status" == 0 ]] || {
      cat "$scratch/result" >&2
      fail "$mode failed"
    }
    grep -q 'release-contract: OK' "$scratch/result" || fail 'healthy control did not reach the real validator'
  else
    producer="${mode%%-*}"
    grep -qx "$producer" "$scratch/trace" || fail "$mode did not execute its intended Git producer"
    grep -q "injected Git $producer failure" "$scratch/result" || fail "$mode failed for an unrelated reason"
    [[ "$status" != 0 ]] || fail "producer $mode reported success"
  fi
done
if [[ "${DEPLOY_GUARDS_SKIP_MUTATION:-}" != 1 ]]; then
  yq '(.runs.steps[] | select(.name == "🚦 Validate release contract") | .run) |= "set +o pipefail\n" + .' "$action" >"$scratch/default-shell.yaml"
  if DEPLOY_GUARDS_SKIP_MUTATION=1 DEPLOY_GUARDS_ACTION="$scratch/default-shell.yaml" \
    bash "$repo_root/tests/deploy-guards-ruleset.sh" >"$scratch/mutation" 2>&1; then
    fail 'removing explicit pipeline semantics passed the regression'
  fi
  grep -q 'producer log-empty reported success' "$scratch/mutation" || {
    cat "$scratch/mutation" >&2
    fail 'default-shell mutation failed for an unrelated reason'
  }
fi

echo "deploy-guards-ruleset: OK"
