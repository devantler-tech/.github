#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/ci.yaml}
gate='.jobs.ci-required-checks'

fail() {
  printf 'ci-required-checks boundary: %s\n' "$1" >&2
  exit 1
}

[ -f "$workflow" ] || fail "workflow not found: $workflow"

permissions=$(yq -o=json -I=0 "$gate.permissions" "$workflow")
[ "$permissions" = '{}' ] ||
  fail "the required gate must have no token permissions, got: $permissions"

uses_steps=$(yq -r "$gate.steps[]? | select(.uses != null) | .uses" "$workflow")
[ -z "$uses_steps" ] ||
  fail "the required gate must not execute checked-out or external actions, got: $uses_steps"

step_count=$(yq -r "[$gate.steps[]? | select(.name == \"📊 Summarize workflow result\")] | length" "$workflow")
[ "$step_count" = '1' ] ||
  fail "expected exactly one inline summary step, got: $step_count"

script=$(yq -r "$gate.steps[] | select(.name == \"📊 Summarize workflow result\") | .run" "$workflow")
[ -n "$script" ] && [ "$script" != 'null' ] ||
  fail "the inline summary step has no executable script"

run_case() {
  local label=$1 input=$2 expected=$3 needle=$4 output rc=0

  output=$(JOB_RESULTS="$input" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS='[]' NEEDS_JSON='{"test-enable-auto-merge-queue":{"result":"skipped"},"test-go-workflow-guards":{"result":"skipped"}}' bash -c "$script" 2>&1) || rc=$?

  if [ "$expected" = pass ] && [ "$rc" -ne 0 ]; then
    fail "$label should pass, got exit $rc: $output"
  fi
  if [ "$expected" = fail ] && [ "$rc" -eq 0 ]; then
    fail "$label should fail closed, got exit 0: $output"
  fi
  if [[ "$output" != *"$needle"* ]]; then
    fail "$label should explain the result with '$needle', got: $output"
  fi
}

run_case 'success and skipped results' 'success skipped' pass 'all jobs succeeded or were skipped'
run_case 'failed result' 'success failure' fail 'failed or was cancelled'
run_case 'cancelled result' 'cancelled' fail 'failed or was cancelled'
run_case 'unknown result' 'success pending' fail "unknown job result: 'pending'"
run_case 'empty result list' '' fail 'no job results were provided'

# A successful selector cannot make a selected-but-skipped test green. Execute
# the actual reducer, not an independent model of its intended behavior.
selection_case() {
  local label=$1 selector=$2 selected=$3 needs=$4 expected=$5 rc=0 output
  # These unit cases omit the unselected queue. Include its actual skipped
  # dependency result; native queue execution is exercised by the API fixtures.
  local complete
  if complete=$(jq -c 'if type == "object" then
    (if has("test-enable-auto-merge-queue") then . else . + {"test-enable-auto-merge-queue":{"result":"skipped"}} end)
    else . end' <<<"$needs" 2>/dev/null); then
    needs=$complete
  fi
  output=$(JOB_RESULTS='success skipped' CATALOGUE_REQUIRED="${6:-true}" SELECTOR_RESULT="$selector" SELECTED_JOBS="$selected" NEEDS_JSON="$needs" bash -c "$script" 2>&1) || rc=$?
  if [[ "$expected" == fail && "$rc" == 0 ]]; then
    fail "$label was silently accepted"
  fi
  if [[ "$expected" == pass && "$rc" != 0 ]]; then
    fail "$label failed: $output"
  fi
}
selection_case 'selected successful test' success '["test-one"]' '{"test-one":{"result":"success"},"test-go-workflow-guards":{"result":"skipped"}}' pass
selection_case 'selected skipped test' success '["test-one"]' '{"test-one":{"result":"skipped"},"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'selected missing test' success '["test-one"]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'failed selector' failure '[]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'skipped selector' skipped '[]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'missing selection evidence' success '' '{"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'non-array selection evidence' success '{}' '{"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'duplicate selected jobs' success '["test-one","test-one"]' '{"test-one":{"result":"success"},"test-go-workflow-guards":{"result":"skipped"}}' fail
selection_case 'malformed results evidence' success '[]' 'invalid' fail
selection_case 'original excluded-event skip' skipped '' '{"test-go-workflow-guards":{"result":"skipped"}}' pass false
selection_case 'executed selector on excluded event' success '[]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail false
selection_case 'manufactured excluded-event selection' skipped '["test-one"]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail false
selection_case 'unknown event eligibility' success '[]' '{"test-go-workflow-guards":{"result":"skipped"}}' fail unknown
selection_case 'unselected missing physical group' success '[]' '{}' fail
selection_case 'selected missing physical group' success '["test-go-workflow-guards"]' '{}' fail

# A green physical runner must not conceal an unexecuted logical member.
group=test-go-workflow-guards
members='["test-go-filter-nested-modules","test-go-filter-nested-modules-blocks","test-govulncheck-main-coverage","test-govulncheck-main-coverage-blocks"]'
group_selected='["test-go-workflow-guards"]'
group_needs=$(jq -cn --arg group "$group" --argjson members "$members" '
  {($group):{result:"success",outputs:($members|map({key:.,value:"success"})|from_entries)}}')
selection_case 'all grouped members succeeded' success "$group_selected" "$group_needs" pass
selection_case 'group missing member outcomes' success "$group_selected" '{"test-go-workflow-guards":{"result":"success"}}' fail
for outcome in failure cancelled skipped; do
  bad=$(jq -c --arg group "$group" --arg outcome "$outcome" '.[$group].result=$outcome' <<<"$group_needs")
  selection_case "physical group was $outcome" success "$group_selected" "$bad" fail
done
for member in $(jq -r '.[]' <<<"$members"); do
  for outcome in failure cancelled skipped unknown '' true; do
    bad=$(jq -c --arg group "$group" --arg member "$member" --arg outcome "$outcome" '.[$group].outputs[$member]=$outcome' <<<"$group_needs")
    selection_case "group member $member was $outcome" success "$group_selected" "$bad" fail
  done
  bad=$(jq -c --arg group "$group" --arg member "$member" 'del(.[$group].outputs[$member])' <<<"$group_needs")
  selection_case "missing grouped member $member" success "$group_selected" "$bad" fail
done
for mutation in '.outputs=null' '.outputs=[]' '.outputs="success"' '.outputs.extra="success"' \
  '.outputs["test-go-filter-nested-modules"]=true' '.outputs["test-go-filter-nested-modules"]=null'; do
  bad=$(jq -c --arg group "$group" '.[$group] |= ('"$mutation"')' <<<"$group_needs")
  selection_case 'malformed grouped outputs' success "$group_selected" "$bad" fail
done
selection_case 'unselected group must skip' success '[]' "$group_needs" fail
selection_case 'excluded event must skip group' skipped '' "$group_needs" fail false

# Bind the four logical results to the actual direct invocations, never a
# constant success or a sibling's outcome. This remains one closed local group.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$workflow" >"$work/workflow.json"
cat >"$work/group.jq" <<'JQ'
  .jobs["test-go-workflow-guards"] as $g |
  $g.needs == ["select-ci-tests"] and $g["runs-on"] == "ubuntu-latest" and
  $g["timeout-minutes"] == 5 and $g.permissions == {"contents":"read"} and
  $g.uses == null and $g.env == null and $g.strategy == null and $g.container == null and $g.services == null and
  ($g["continue-on-error"] == null or $g["continue-on-error"] == false) and
  ($g.steps | length) == 6 and
  ($g.steps[0].uses | startswith("step-security/harden-runner@")) and
  ($g.steps[1].uses | startswith("actions/checkout@")) and $g.steps[1].with["persist-credentials"] == false and
  $g.outputs == {
    "test-govulncheck-main-coverage":"${{ steps.test-govulncheck-main-coverage.outcome }}",
    "test-govulncheck-main-coverage-blocks":"${{ steps.test-govulncheck-main-coverage-blocks.outcome }}",
    "test-go-filter-nested-modules":"${{ steps.test-go-filter-nested-modules.outcome }}",
    "test-go-filter-nested-modules-blocks":"${{ steps.test-go-filter-nested-modules-blocks.outcome }}"
  } and
  [$g.steps[2:][] | {id,run,shell,if}] == [
    {id:"test-govulncheck-main-coverage",run:"bash .github/tests/test-govulncheck-main-coverage.sh",shell:"bash",if:"${{ !cancelled() }}"},
    {id:"test-govulncheck-main-coverage-blocks",run:"bash .github/tests/test-govulncheck-main-coverage-blocks.sh",shell:"bash",if:"${{ !cancelled() }}"},
    {id:"test-go-filter-nested-modules",run:"bash .github/tests/test-go-filter-nested-modules.sh",shell:"bash",if:"${{ !cancelled() }}"},
    {id:"test-go-filter-nested-modules-blocks",run:"bash .github/tests/test-go-filter-nested-modules-blocks.sh",shell:"bash",if:"${{ !cancelled() }}"}
  ] and all($g.steps[2:][];
    (.env == null) and (.["working-directory"] == null or .["working-directory"] == ".") and
    (.["continue-on-error"] == null or .["continue-on-error"] == false))
JQ
check_group() { jq -e -f "$work/group.jq" "$1" >/dev/null; }
check_group "$work/workflow.json" || fail 'grouped guards lack exact commands, outcomes or independent execution'
for member in $(jq -r '.[]' <<<"$members"); do
  # shellcheck disable=SC2016 # GitHub expressions are literal fixture data.
  for expression in success '${{ steps.other.outcome }}' '${{ steps.other.conclusion }}'; do
    jq --arg group "$group" --arg member "$member" --arg expression "$expression" '.jobs[$group].outputs[$member]=$expression' \
      "$work/workflow.json" >"$work/bad.json"
    if check_group "$work/bad.json"; then fail "unbound grouped output accepted: $member"; fi
  done
done
# shellcheck disable=SC2016 # GitHub expressions are literal fixture data.
for mutation in \
  'del(.outputs["test-govulncheck-main-coverage"])' \
  '.steps[2].run="true"' 'del(.steps[2].if)' '.steps[3].if="${{ success() }}"' '.steps[4].shell="true {0}"' \
  '.steps[5]["working-directory"]="fixture"' '.steps[2]["continue-on-error"]=true' \
  '.needs=["select-ci-tests","other"]' '.permissions.contents="write"'; do
  jq --arg group "$group" '.jobs[$group] |= ('"$mutation"')' "$work/workflow.json" >"$work/bad.json"
  if check_group "$work/bad.json"; then fail "unsafe grouped invocation accepted: $mutation"; fi
done

# Execute the four actual Bash commands. One controlled yq producer fails in
# each case; the other independent commands must still execute and pass. The
# exact !cancelled() binding above is checked separately; native CI must also
# verify GitHub's scheduling and the exported step outcomes.
mkdir "$work/bin"
real_yq=$(command -v yq)
cat >"$work/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$GUARD_MEMBER" == "$FAILED_GUARD" ]]; then exit 23; fi
exec "$REAL_YQ" "$@"
SH
chmod +x "$work/bin/yq"
jq -r '.jobs["test-go-workflow-guards"].steps[2:][] | [.id,.run]|@tsv' "$work/workflow.json" >"$work/commands"
for failed in $(jq -r '.[]' <<<"$members"); do
  count=0
  while IFS=$'\t' read -r member command; do
    rc=0
    PATH="$work/bin:$PATH" REAL_YQ="$real_yq" GUARD_MEMBER="$member" FAILED_GUARD="$failed" \
      bash -euo pipefail -c "$command" >"$work/command.log" 2>&1 || rc=$?
    if [[ "$member" == "$failed" ]]; then
      [[ "$rc" != 0 ]] || fail "controlled producer did not fail the actual guard: $member"
    elif [[ "$rc" != 0 ]]; then
      cat "$work/command.log" >&2
      fail "independent actual guard did not pass after $failed: $member"
    fi
    count=$((count + 1))
  done <"$work/commands"
  [[ "$count" == 4 ]] || fail 'grouped invocation fixture did not execute all four guards'
  printf 'PASS: %s failed; all four actual guard commands executed\n' "$failed"
done

printf 'ci-required-checks boundary and behavior are enforced\n'
