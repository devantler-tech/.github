#!/usr/bin/env bash
# Exercise the actual selector contract and complete current workflow inventory.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ci="$root/.github/workflows/ci.yaml"
yq -o=json . "$ci" > "$work/workflow.json"
# The full reducer now consumes native queue evidence in its own allocation.
# Keep this selector integration offline while executing that same reducer.
mkdir "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api repos/devantler-tech/fixture/actions/runs/123/attempts/2/jobs?per_page=50 --paginate --slurp' ]] || exit 99
cat "$QUEUE_FIXTURE"
SH
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" QUEUE_FIXTURE="$root/.github/tests/fixtures/queue-slots.json"
export REPOSITORY=devantler-tech/fixture RUN_ID=123 RUN_ATTEMPT=2 HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$work/preflight.jq" <<'JQ'
  .jobs["select-ci-tests"] as $s |
  (.jobs | has("catalogue-scope") | not) and
  ($s.if == "${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}") and
  ($s.needs == null) and
  ($s | has("continue-on-error") | not) and
  ($s.permissions == {"contents":"read"}) and
  ($s.outputs.selected == "${{ steps.select.outputs.selected }}") and
  ($s.outputs.catalogue == "${{ steps.scope.outputs.catalogue }}") and
  ($s.steps | length == 5) and
  ($s.steps[0].uses | startswith("step-security/harden-runner@")) and
  ([$s.steps[1], $s.steps[3]] | all(.uses | startswith("actions/checkout@"))) and
  ($s.steps[1].with == {"ref":"${{ github.event.pull_request.base.sha || github.sha }}","fetch-depth":0,"persist-credentials":false}) and
  ($s.steps[3].with == {"fetch-depth":0,"persist-credentials":false}) and
  ($s.steps[2].id == "scope") and
  ($s.steps[4].id == "select") and
  ([$s.steps[1:][] | .if] | all(. == null)) and
  ([$s.steps[] | ."continue-on-error"] | all(. == null or . == false)) and
  ([$s.steps[] | select(.id == "select") | .env.GOWORK] == ["off"]) and
  ([$s.steps[] | select(.id == "select") | .env.GOFLAGS] == [""]) and
  ([$s.steps[] | select(.id == "select") | .env.GOTOOLCHAIN] == ["local"]) and
  ([$s.steps[] | select(.id == "select") | .env.CATALOGUE_SCOPE] == ["${{ steps.scope.outputs.catalogue }}"]) and
  (.jobs["ci-required-checks"].needs | index("select-ci-tests") != null)
JQ
if ! jq -e -f "$work/preflight.jq" "$work/workflow.json" > /dev/null; then
  echo 'FAIL: classification and selection must share one runner with ordered trusted-base and candidate checkouts' >&2
  exit 1
fi
for mutation in \
  'del(.jobs["select-ci-tests"].steps[1].with.ref)' \
  '.jobs["select-ci-tests"].steps |= [.[0], .[3], .[2], .[1], .[4]]' \
  '.jobs["select-ci-tests"].steps[2].if = "false"' \
  '.jobs["select-ci-tests"].steps[2]."continue-on-error" = true' \
  '.jobs["select-ci-tests"].steps[1].with."persist-credentials" = true' \
  '.jobs["select-ci-tests"].steps[4].env.CATALOGUE_SCOPE = "true"' \
  '.jobs["select-ci-tests"].steps |= [.[0], .[1], .[4], .[3], .[2]]' \
  'del(.jobs["ci-required-checks"].needs[] | select(. == "select-ci-tests"))'; do
  jq "$mutation" "$work/workflow.json" > "$work/unsafe.json"
  if jq -e -f "$work/preflight.jq" "$work/unsafe.json" > /dev/null; then
    echo "FAIL: unsafe preflight mutation accepted: $mutation" >&2
    exit 1
  fi
done
go -C "$root/.github/scripts/ci-selection" test -race -count=3 ./...
go -C "$root/.github/scripts/ci-selection" vet ./...
# Remove every .NET owner from both production inputs. This must fail before
# selection, even though the remaining inventory still matches the workflow.
dotnet_owners='["test-run-dotnet-tests-gate-lockstep","test-run-dotnet-tests-mtp","test-run-dotnet-tests-workflow","test-run-dotnet-tests-workflow-authenticated"]'
jq --argjson owners "$dotnet_owners" 'del(.jobs[$owners[]])' "$work/workflow.json" > "$work/ownerless-workflow.json"
jq --argjson owners "$dotnet_owners" 'del(.jobs[$owners[]], .preserved[$owners[]])' "$root/.github/scripts/ci-selection/inventory.json" > "$work/ownerless-inventory.json"
if EVENT_NAME=push RUN_CATALOGUE=true CATALOGUE_SCOPE=true GITHUB_OUTPUT="$work/ownerless-output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$work/ownerless-inventory.json" "$work/ownerless-workflow.json" > "$work/ownerless.log" 2>&1; then
  echo 'FAIL: production entrypoint accepted removal of every required .NET owner' >&2
  exit 1
fi
grep -q 'incomplete or unbound .NET workflow owner' "$work/ownerless.log"
[[ ! -e "$work/ownerless-output" ]]
touch "$work/output"
EVENT_NAME=push RUN_CATALOGUE=true CATALOGUE_SCOPE=true GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
selected="$(sed -n 's/^selected=//p' "$work/output")"
# The skill action executions moved with their standalone repositories; all remaining executions stay selected.
jq -e 'length == 61 and index("test-lint-workflow") == null and
  index("test-lint-workflow-manual-fixes") == null' <<< "$selected" >/dev/null
jq -e 'index("test-validate-go-postgresql-fixture") != null' <<<"$selected" >/dev/null
jq -e 'index("test-go-cache-native-observer") != null' <<<"$selected" >/dev/null
# Hosted CI reports these callers as skipped because their callee jobs are
# intentionally excluded (dry-run, repository exclusion, or dependency-bot
# suppression). They still exercise interfaces and retain original admission;
# selection must not promise an executed test where no job can run.
interface_callers='["test-apply-signed-fixes-suppresses-bots","test-template-sync","test-template-sync-merge-ignore","test-validate-go-project-interface"]'
needs="$(jq -cn --argjson skipped "$interface_callers" --slurpfile workflow "$work/workflow.json" '
  reduce ($workflow[0].jobs | keys[]) as $id ({};
    .[$id] = {result: (if ($skipped | index($id)) != null then "skipped" else "success" end)}) |
  .["test-go-workflow-guards"].outputs = {
    "test-govulncheck-main-coverage":"success","test-govulncheck-main-coverage-blocks":"success",
    "test-go-filter-nested-modules":"success","test-go-filter-nested-modules-blocks":"success"}
')"
reducer="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .run' "$ci")"
# Native evidence files belong to this offline fixture, never the checkout.
run_reducer() { (cd "$work"; bash -c "$reducer"); }

JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" run_reducer || {
  echo "FAIL: intentional interface-only caller skips incorrectly failed hosted selection" >&2
  exit 1
}
# Main's push event also intentionally excludes these two reusable callees.
# Reproduce that hosted result map through the production selector and reducer.
pr_only_callers='["test-dependency-review-workflow","test-apply-signed-fixes-verifies-without-a-patch"]'
main_needs="$(jq --argjson skipped "$pr_only_callers" 'reduce $skipped[] as $id (.; .[$id].result="skipped")' <<< "$needs")"
JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$main_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$main_needs" run_reducer || {
  echo "FAIL: intentional PR-only caller skips incorrectly failed main selection" >&2
  exit 1
}
# A failed preserved call must still fail the global reducer. Expected callee
# exclusions may skip; every selected execution remains mandatory.
for caller in $(jq -nr --argjson interface "$interface_callers" --argjson pr_only "$pr_only_callers" '$interface + $pr_only | .[]'); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="failure"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer > /dev/null 2>&1; then
    echo "FAIL: failed preserved caller $caller was silently accepted" >&2
    exit 1
  fi
done
for caller in $(jq -r '.[]' <<< "$selected"); do
  bad_needs="$(jq --arg caller "$caller" '.[$caller].result="skipped"' <<< "$needs")"
  if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer > /dev/null 2>&1; then
    echo "FAIL: selected execution $caller was silently skipped" >&2
    exit 1
  fi
done
EVENT_NAME=merge_group RUN_CATALOGUE=false GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$root" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
[[ "$(tail -n 1 "$work/output")" == 'selected=[]' ]]
# Independently verify all direct local action callers have their exact owner.
check_action_owners() {
  jq -e --slurpfile inventory "$1" '
    all(.jobs | to_entries[] | select(.key | startswith("test-"));
      .key as $id | all(.value.steps[]? | .uses? // empty | select(startswith("./actions/") or startswith("$/actions/"));
        (.[2:] + "/") as $owner | $inventory[0].jobs[$id] | index($owner) != null))
  ' "$work/workflow.json" > /dev/null
}
check_action_owners "$root/.github/scripts/ci-selection/inventory.json"
# A native action must not disappear from the independent ownership check.
jq '.jobs["test-validate-naming"] = []' "$root/.github/scripts/ci-selection/inventory.json" >"$work/missing-action-owner.json"
if check_action_owners "$work/missing-action-owner.json"; then
  echo 'FAIL: native action without a selector owner was accepted' >&2
  exit 1
fi


# The same exact Git diff formerly selected every gated job. Its four reviewed
# dependencies include two native callers and two inline controls; the authenticated
# caller retains independent admission and is not promised as a mandatory execution.
dotnet="$work/dotnet"
mkdir -p "$dotnet/.github/workflows"
git init -q "$dotnet"
git -C "$dotnet" config user.name 'CI fixture'
git -C "$dotnet" config user.email 'fixture@example.invalid'
git -C "$dotnet" config commit.gpgsign false
mkdir -p "$dotnet/.github/actions/test-dotnet-fixture"
printf 'base\n' > "$dotnet/.github/actions/test-dotnet-fixture/action.yaml"
git -C "$dotnet" add -- .github/actions/test-dotnet-fixture/action.yaml
git -C "$dotnet" commit -qm 'test: dotnet baseline'
base="$(git -C "$dotnet" rev-parse HEAD)"
printf 'changed\n' > "$dotnet/.github/actions/test-dotnet-fixture/action.yaml"
git -C "$dotnet" add -- .github/actions/test-dotnet-fixture/action.yaml
git -C "$dotnet" commit -qm 'test: dotnet change'
head="$(git -C "$dotnet" rev-parse HEAD)"
: > "$work/output"
EVENT_NAME=pull_request RUN_CATALOGUE=true CATALOGUE_SCOPE=true BASE_SHA="$base" HEAD_SHA="$head" GITHUB_OUTPUT="$work/output" \
  go -C "$root/.github/scripts/ci-selection" run . "$dotnet" "$root/.github/scripts/ci-selection/inventory.json" "$work/workflow.json"
selected="$(sed -n 's/^selected=//p' "$work/output")"
jq -e '. == ["test-run-dotnet-tests-gate-lockstep","test-run-dotnet-tests-mtp","test-run-dotnet-tests-workflow"]' <<< "$selected" >/dev/null
needs="$(jq -cn --argjson selected "$selected" 'reduce $selected[] as $id ({"test-run-dotnet-tests-workflow-authenticated":{result:"skipped"},"test-enable-auto-merge-queue":{result:"skipped"},"test-go-workflow-guards":{result:"skipped"}}; .[$id] = {result:"success"})')"
JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" run_reducer
for caller in $(jq -r '.[]' <<< "$selected"); do
  for outcome in skipped failure; do
    bad_needs="$(jq --arg caller "$caller" --arg outcome "$outcome" '.[$caller].result=$outcome' <<< "$needs")"
    if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<< "$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer >/dev/null 2>&1; then
      echo "FAIL: selected .NET execution $caller was $outcome without rejection" >&2
      exit 1
    fi
  done
done
bad_needs="$(jq '."test-run-dotnet-tests-workflow-authenticated".result="failure"' <<< "$needs")"
if JOB_RESULTS='success failure' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer >/dev/null 2>&1; then
  echo 'FAIL: independently admitted authenticated caller failure was concealed' >&2
  exit 1
fi

# Root documents route only to the gated jobs that actually read them. Derive
# that reader set from the tracked workflow and executed scripts, and prove the
# derivation rejects a missing, invented or new reader.
readers="$root/.github/tests/ci-selection-document-readers.sh"
inventory="$root/.github/scripts/ci-selection/inventory.json"
bash "$readers" "$root" "$inventory" "$work/workflow.json"
reject_readers() { # description expected-reason inventory workflow
  if bash "$readers" "$root" "$3" "$4" >"$work/readers.log" 2>&1 || ! grep -qF -- "$2" "$work/readers.log"; then
    echo "FAIL: document reader guard did not reject $1 with: $2" >&2
    cat "$work/readers.log" >&2
    exit 1
  fi
}
route='README.md route differs from its tracked gated readers'
unreviewed='unreviewed AGENTS.md or whole-checkout read'
jq '.jobs["test-lint-gate-lockstep"] -= ["README.md"]' "$inventory" >"$work/readers-inventory.json"
reject_readers 'a README reader without its route' "$route" "$work/readers-inventory.json" "$work/workflow.json"
jq '.jobs["test-upload-coverage"] += ["README.md"]' "$inventory" >"$work/readers-inventory.json"
reject_readers 'an invented README reader' "$route" "$work/readers-inventory.json" "$work/workflow.json"
jq '.jobs["test-approve-pr"] += ["AGENTS.md"]' "$inventory" >"$work/readers-inventory.json"
reject_readers 'an AGENTS.md owner' 'AGENTS.md has no gated reader' "$work/readers-inventory.json" "$work/workflow.json"
for step in 'cat README.md' 'grep -q Agents AGENTS.md' 'cp -R . /tmp/copy' 'tar -cf /tmp/all.tar .'; do
  reason="$unreviewed"
  [[ "$step" != *README* ]] || reason="$route"
  jq --arg run "$step" '.jobs["test-approve-pr"].steps += [{"run": $run}]' "$work/workflow.json" >"$work/readers-workflow.json"
  reject_readers "an unrouted new reader: $step" "$reason" "$inventory" "$work/readers-workflow.json"
done
# A reader reached only through an executed script is still a reader; a
# script that never reads the documents keeps the route unchanged.
jq '.jobs["test-approve-pr"].steps += [{"run": "bash .github/tests/test-catalogue-pin-guards-controls.sh"}]' "$work/workflow.json" >"$work/readers-workflow.json"
reject_readers 'a transitive README reader' "$route" "$inventory" "$work/readers-workflow.json"
jq '.jobs["test-approve-pr"].steps += [{"run": "bash .github/tests/test-approve-pr-credential-boundary.sh"}]' "$work/workflow.json" >"$work/readers-workflow.json"
bash "$readers" "$root" "$inventory" "$work/readers-workflow.json" >/dev/null

# A reviewed exemption that no longer names a real line must not linger.
awk '{ print } /^cat >"\$work\/non-reading" <<'"'"'LINES'"'"'$/ { print "actions/approve-pr/action.yaml|cat README.md" }' "$readers" >"$work/stale-readers.sh"
if bash "$work/stale-readers.sh" "$root" "$inventory" "$work/workflow.json" >"$work/readers.log" 2>&1 ||
  ! grep -qF 'stale non-reading exemption' "$work/readers.log"; then
  echo 'FAIL: document reader guard kept a stale exemption' >&2
  exit 1
fi

# Exercise real root-document change sets through the production selector and
# the required reducer. Narrow routes still require every selected success.
docs="$work/docs"
mkdir -p "$docs/actions/approve-pr"
git init -q "$docs"
git -C "$docs" config user.name 'CI fixture'
git -C "$docs" config user.email 'fixture@example.invalid'
git -C "$docs" config commit.gpgsign false
printf 'readme\n' >"$docs/README.md"
printf 'agents\n' >"$docs/AGENTS.md"
printf 'action\n' >"$docs/actions/approve-pr/action.yaml"
git -C "$docs" add -- README.md AGENTS.md actions/approve-pr/action.yaml
git -C "$docs" commit -qm 'test: documents baseline'
docs_base="$(git -C "$docs" rev-parse HEAD)"
select_docs() { # change-kind... ; prints the selected JSON
  git -C "$docs" checkout -q --detach "$docs_base"
  local change
  for change in "$@"; do
    case "$change" in
      readme) printf 'readme change\n' >>"$docs/README.md" ;;
      agents) printf 'agents change\n' >>"$docs/AGENTS.md" ;;
      action) printf 'action change\n' >>"$docs/actions/approve-pr/action.yaml" ;;
      unknown) printf 'unknown\n' >"$docs/unclassified.txt" ;;
      readme-renamed) git -C "$docs" mv README.md docs-readme.md ;;
    esac
  done
  git -C "$docs" add -A -- .
  git -C "$docs" commit -qm "test: $*"
  : >"$work/docs-output"
  EVENT_NAME=pull_request RUN_CATALOGUE=true CATALOGUE_SCOPE=true BASE_SHA="$docs_base" \
    HEAD_SHA="$(git -C "$docs" rev-parse HEAD)" GITHUB_OUTPUT="$work/docs-output" \
    go -C "$root/.github/scripts/ci-selection" run . "$docs" "$inventory" "$work/workflow.json" >/dev/null
  sed -n 's/^selected=//p' "$work/docs-output"
}
readme_readers='["test-enable-auto-merge-author-gate","test-enable-auto-merge-pentad-gate","test-lint-gate-lockstep","test-validate-go-gate-lockstep"]'
action_only="$(select_docs action)"
jq -e '. == ["test-approve-pr","test-approve-pr-credential-boundary"]' <<<"$action_only" >/dev/null
jq -e --argjson want "$readme_readers" '. == $want' <<<"$(select_docs readme)" >/dev/null ||
  { echo 'FAIL: README-only change did not select exactly its readers' >&2; exit 1; }
jq -e --argjson want "$action_only" '. == $want' <<<"$(select_docs action agents)" >/dev/null ||
  { echo 'FAIL: AGENTS.md companion changed a recognized action selection' >&2; exit 1; }
jq -e --argjson a "$action_only" --argjson r "$readme_readers" '. == ($a + $r | unique)' <<<"$(select_docs action readme agents)" >/dev/null ||
  { echo 'FAIL: README with a recognized action lost a reader or an owner' >&2; exit 1; }
for kinds in 'agents' 'readme agents' 'readme unknown' 'action agents unknown' 'readme-renamed'; do
  # shellcheck disable=SC2086 # Each kinds word is one fixture change.
  jq -e 'length == 61' <<<"$(select_docs $kinds)" >/dev/null ||
    { echo "FAIL: root-document change '$kinds' narrowed full coverage" >&2; exit 1; }
done
for kinds in 'readme' 'action readme agents'; do
  # shellcheck disable=SC2086 # Each kinds word is one fixture change.
  selected="$(select_docs $kinds)"
  needs="$(jq -cn --argjson selected "$selected" 'reduce $selected[] as $id ({"test-enable-auto-merge-queue":{result:"skipped"},"test-go-workflow-guards":{result:"skipped"}}; .[$id] = {result:"success"})')"
  JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$needs" run_reducer >/dev/null
  for caller in $(jq -r '.[]' <<<"$selected"); do
    for outcome in skipped failure; do
      bad_needs="$(jq --arg caller "$caller" --arg outcome "$outcome" '.[$caller].result=$outcome' <<<"$needs")"
      if JOB_RESULTS="$(jq -r '[.[].result] | join(" ")' <<<"$bad_needs")" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="$selected" NEEDS_JSON="$bad_needs" run_reducer >/dev/null 2>&1; then
        echo "FAIL: selected root-document reader $caller was $outcome without rejection" >&2
        exit 1
      fi
    done
  done
done
echo 'PASS: complete job inventory, owner coverage and preserved scheduling'
