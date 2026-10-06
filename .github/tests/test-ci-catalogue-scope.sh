#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${repo_root}/.github/scripts/classify-ci-catalogue.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "${fixture}"' EXIT

fail() { echo "CI catalogue scope: $*" >&2; exit 1; }

new_repo() {
  local name="$1"
  current="${fixture}/${name}"
  mkdir -p "${current}/deploy" "${current}/tests" "${current}/actions/example"
  git init -q "${current}"
  git -C "${current}" config user.name 'CI Scope Fixture'
  git -C "${current}" config user.email 'fixture@example.invalid'
  printf 'base\n' >"${current}/deploy/example.yaml"
  printf 'base\n' >"${current}/tests/platform-merge-queue-ruleset.sh"
  printf 'base\n' >"${current}/actions/example/action.yaml"
  git -C "${current}" add -- deploy/example.yaml tests/platform-merge-queue-ruleset.sh actions/example/action.yaml
  git -C "${current}" -c commit.gpgsign=false commit -qm 'test: fixture base'
  base="$(git -C "${current}" rev-parse HEAD)"
}

commit_change() {
  git -C "${current}" -c commit.gpgsign=false commit -qm 'test: fixture change'
  head="$(git -C "${current}" rev-parse HEAD)"
}

assert_scope() {
  local expected="$1" actual
  actual="$(cd "${current}" && bash "${helper}" "${base}" "${head}")" || fail 'classifier failed'
  [[ "${actual}" == "catalogue=${expected}" ]] || fail "expected ${expected}, got ${actual}"
}

new_repo deployment
printf 'changed\n' >"${current}/deploy/example.yaml"
printf 'changed\n' >"${current}/tests/platform-merge-queue-ruleset.sh"
git -C "${current}" add -- deploy/example.yaml tests/platform-merge-queue-ruleset.sh
commit_change
assert_scope false

new_repo base_advances
printf 'changed\n' >"${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
git -C "${current}" checkout -q --detach "${base}"
printf 'base moved\n' >"${current}/actions/example/action.yaml"
git -C "${current}" add -- actions/example/action.yaml
git -C "${current}" -c commit.gpgsign=false commit -qm 'test: shared base advances'
base="$(git -C "${current}" rev-parse HEAD)"
assert_scope false

new_repo shared
printf 'changed\n' >"${current}/deploy/example.yaml"
printf 'changed\n' >"${current}/actions/example/action.yaml"
git -C "${current}" add -- deploy/example.yaml actions/example/action.yaml
commit_change
assert_scope true

new_repo added
printf 'new\n' >"${current}/deploy/new.yaml"
git -C "${current}" add -- deploy/new.yaml
commit_change
assert_scope true

new_repo deleted
git -C "${current}" rm -q -- deploy/example.yaml
commit_change
assert_scope true

new_repo renamed
git -C "${current}" mv -- actions/example/action.yaml deploy/renamed.yaml
commit_change
assert_scope true

new_repo symlink
rm "${current}/deploy/example.yaml"
ln -s ../actions/example/action.yaml "${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
assert_scope true

new_repo changed_symlink
rm "${current}/deploy/example.yaml"
ln -s ../actions/example/action.yaml "${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
git -C "${current}" -c commit.gpgsign=false commit -qm 'test: base symlink'
base="$(git -C "${current}" rev-parse HEAD)"
rm "${current}/deploy/example.yaml"
ln -s ../tests/platform-merge-queue-ruleset.sh "${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
assert_scope true

new_repo unknown_test
printf 'new\n' >"${current}/tests/new.sh"
git -C "${current}" add -- tests/new.sh
commit_change
assert_scope true

new_repo unchanged
head="${base}"
assert_scope true

new_repo invalid_anchor
head='--output=unsafe'
assert_scope true
head='0000000000000000000000000000000000000000'
assert_scope true

# Real Git objects identify both anchors; a diff failure or truncated NUL record
# must still select the full catalogue. Nothing from the failed read is accepted.
new_repo failed_read
printf 'changed\n' >"${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
real_git="$(command -v git)"
mkdir "${fixture}/bin"
cat >"${fixture}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == diff ]]; then
  printf 'M\0deploy/example.yaml\0'
  exit 1
fi
exec "${REAL_GIT}" "$@"
STUB
chmod +x "${fixture}/bin/git"
actual="$(cd "${current}" && REAL_GIT="${real_git}" PATH="${fixture}/bin:${PATH}" bash "${helper}" "${base}" "${head}")"
[[ "${actual}" == catalogue=true ]] || fail 'failed diff narrowed the catalogue'
cat >"${fixture}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == diff ]]; then
  printf 'M\0deploy/example.yaml'
  exit 0
fi
exec "${REAL_GIT}" "$@"
STUB
actual="$(cd "${current}" && REAL_GIT="${real_git}" PATH="${fixture}/bin:${PATH}" bash "${helper}" "${base}" "${head}")"
[[ "${actual}" == catalogue=true ]] || fail 'truncated diff narrowed the catalogue'

ci="${repo_root}/.github/workflows/ci.yaml"
selector="$(yq -r '.jobs."select-ci-tests".steps[]? | select(.name == "Classify exact PR scope") | .run' "${ci}")"
[[ -n "${selector}" ]] || fail 'trusted classification step is absent'
checkout="$(yq -o=json -I=0 '.jobs."select-ci-tests".steps' "${ci}" | jq '[.[] | select((.uses // "") | startswith("actions/checkout@"))] | if length == 2 then .[0] else error("expected trusted-base and candidate checkouts") end')"
checkout_ref="$(jq -r '.with.ref' <<<"${checkout}")"
[[ "${checkout_ref}" == "\${{ github.event.pull_request.base.sha || github.sha }}" ]] || fail 'selector executes candidate code'
[[ "$(jq -r '.with."persist-credentials"' <<<"${checkout}")" == false ]] || fail 'selector persists credentials'
[[ "$(jq -r '.with."fetch-depth"' <<<"${checkout}")" == 0 ]] || fail 'selector lacks complete ancestry'
yq -o=json -I=0 '.jobs."ci-required-checks".needs' "${ci}" |
  jq -e 'index("select-ci-tests") != null' >/dev/null || fail 'scope failure cannot reach the required check'
results="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .env.JOB_RESULTS' "${ci}")"
[[ "${results}" == *'needs.select-ci-tests.result'* ]] || fail 'combined preflight result is not aggregated'
[[ "$(yq -r '.jobs."select-ci-tests".needs' "${ci}")" == null ]] || fail 'combined preflight still requires another runner'
[[ "$(yq -r '.jobs."select-ci-tests".steps[] | select(.id == "select") | .env.CATALOGUE_SCOPE' "${ci}")" == "\${{ steps.scope.outputs.catalogue }}" ]] || fail 'selection does not consume the prior trusted classification'
yq -o=json -I=0 '.jobs."test-validate-retired-repo-links".needs' "${ci}" |
  jq -e '. == ["select-ci-tests"]' >/dev/null || fail 'unrelated smoke job ignores selection'
[[ "$(yq -r '.jobs."test-validate-retired-repo-links".if' "${ci}")" == *"contains(fromJSON(needs.select-ci-tests.outputs.selected), 'test-validate-retired-repo-links')"* ]] || fail 'unrelated smoke job ignores selection'
jq -e '.catalogue_optional | index("test-validate-retired-repo-links") != null' "${repo_root}/.github/scripts/ci-selection/inventory.json" >/dev/null || fail 'deployment-only selection retains unrelated smoke job'
[[ "$(yq -r '.jobs."validate-manifests".needs' "${ci}")" == null ]] || fail 'manifest checks became conditional on scope'
[[ "$(yq -r '.jobs."lint-ci-coverage-parity".needs' "${ci}")" == null ]] || fail 'security contract checks became conditional on scope'
[[ "$(yq -r '.jobs."test-dependency-review-comments".needs' "${ci}")" == null ]] || fail 'credential-boundary replay became conditional on scope'
[[ "$(yq -r '.jobs."test-dependency-review-comments".if' "${ci}")" != *'outputs.catalogue'* ]] || fail 'credential-boundary replay ignores its unconditional contract'
yq -o=json -I=0 '.jobs' "${ci}" | jq -e --slurpfile inventory "${repo_root}/.github/scripts/ci-selection/inventory.json" '
  [to_entries[] | select(any(.value.steps[]?; (.run // "") | contains(".github/tests/test-"))) |
    .key as $id |
    select(((.value.needs != null) and (.value.needs != ["select-ci-tests"])) or
      ((.value.if // "") | contains("outputs.catalogue")) or
      (($inventory[0].catalogue_optional | index($id)) != null))] | length == 0
' >/dev/null || fail 'a required test entrypoint became scope-dependent'
yq -o=json -I=0 '.jobs' "${ci}" | jq -e '
  [to_entries[] | select(.value.uses != null) |
    select((.value.if // "") | contains("outputs.catalogue"))] | length == 0
' >/dev/null || fail 'a reusable workflow contract became scope-dependent'

# Exercise the actual workflow shell against an isolated public-shape Git fixture.
# Missing trusted-base helper cannot be taken as permission to omit tests.
printf '%s\n' "${selector}" >"${fixture}/scope-step.sh"
new_repo workflow_missing_helper
printf 'changed\n' >"${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
git -C "${current}" update-ref refs/pull/7/head "${head}"
git -C "${current}" remote add origin "${current}"
output="${fixture}/scope-output"
actual="$(cd "${current}" && GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh")"
[[ "$(cat "${output}")" == catalogue=true ]] || fail 'missing helper narrowed the catalogue'

new_repo workflow_trusted_helper
mkdir -p "${current}/.github/scripts"
cp "${helper}" "${current}/.github/scripts/classify-ci-catalogue.sh"
git -C "${current}" add -- .github/scripts/classify-ci-catalogue.sh
git -C "${current}" -c commit.gpgsign=false commit -qm 'test: trusted base helper'
base="$(git -C "${current}" rev-parse HEAD)"
printf 'changed\n' >"${current}/deploy/example.yaml"
git -C "${current}" add -- deploy/example.yaml
commit_change
git -C "${current}" update-ref refs/pull/7/head "${head}"
git -C "${current}" remote add origin "${current}"
: >"${output}"
(cd "${current}" && GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh")
[[ "$(cat "${output}")" == catalogue=false ]] || fail 'real workflow did not recognize deployment-only changes'

# Compose real Git classification, the production selector and the actual
# required reducer. A false scope omits 48 gated smoke jobs plus the separately
# event-gated dependency-review smoke, not the other 31 selectable jobs or
# the three independently admitted native cleanup callers.
yq -o=json . "${ci}" >"${fixture}/workflow.json"
selection_output="${fixture}/selection-output"
: >"${selection_output}"
scope="$(sed -n 's/^catalogue=//p' "${output}")"
EVENT_NAME=pull_request RUN_CATALOGUE=true CATALOGUE_SCOPE="${scope}" BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${selection_output}" \
  go -C "${repo_root}/.github/scripts/ci-selection" run . "${current}" "${repo_root}/.github/scripts/ci-selection/inventory.json" "${fixture}/workflow.json"
selected="$(sed -n 's/^selected=//p' "${selection_output}")"
[[ "$(jq 'length' <<<"${selected}")" == 34 ]] || fail 'deployment-only selection changed the independent coverage floor'
jq -en --argjson selected "${selected}" --slurpfile inventory "${repo_root}/.github/scripts/ci-selection/inventory.json" '
  ($inventory[0].catalogue_optional | length == 48) and
  all($selected[]; . as $id | ($inventory[0].catalogue_optional | index($id)) == null) and
  ($selected | index("test-approve-pr-credential-boundary") != null) and
  ($selected | index("test-validate-go-project-apply-signed-fixes") != null)
' >/dev/null || fail 'selection omitted an independent credential or signed-fix contract'
reducer="$(yq -r '.jobs."ci-required-checks".steps[] | select(.name == "📊 Summarize workflow result") | .run' "${ci}")"
needs="$(jq -cn --argjson selected "${selected}" --slurpfile inventory "${repo_root}/.github/scripts/ci-selection/inventory.json" '
  reduce ($inventory[0].jobs | keys[]) as $id ({}; .[$id] = {result:(if $selected | index($id) != null then "success" else "skipped" end)})
')"
JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="${selected}" NEEDS_JSON="${needs}" bash -c "${reducer}" || fail 'real deployment-only selection failed the required reducer'
bad_needs="$(jq '."test-approve-pr-credential-boundary".result="skipped"' <<<"${needs}")"
if JOB_RESULTS='success skipped' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success SELECTED_JOBS="${selected}" NEEDS_JSON="${bad_needs}" bash -c "${reducer}"; then
  fail 'selected-but-skipped credential replay was accepted'
fi

: >"${output}"
(cd "${current}" && GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="0000000000000000000000000000000000000000" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh")
[[ "$(cat "${output}")" == catalogue=true ]] || fail 'moved PR head narrowed the catalogue'
git -C "${current}" remote set-url origin "${fixture}/missing-origin"
: >"${output}"
(cd "${current}" && GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh")
[[ "$(cat "${output}")" == catalogue=true ]] || fail 'failed fetch narrowed the catalogue'
: >"${output}"
(cd "${current}" && GITHUB_EVENT_NAME=push GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh")
[[ "$(cat "${output}")" == catalogue=true ]] || fail 'main push narrowed the catalogue'

# A broken trusted classifier must fail the preflight rather than let selection
# inherit a successful decision. This runs the actual workflow shell.
printf '#!/usr/bin/env bash\nexit 23\n' >"${current}/.github/scripts/classify-ci-catalogue.sh"
git -C "${current}" remote set-url origin "${current}"
: >"${output}"
if (cd "${current}" && GITHUB_EVENT_NAME=pull_request GITHUB_REPOSITORY=devantler-tech/.github PR_NUMBER=7 BASE_SHA="${base}" HEAD_SHA="${head}" GITHUB_OUTPUT="${output}" bash "${fixture}/scope-step.sh"); then
  fail 'failed trusted classifier was accepted'
fi
[[ ! -s "${output}" ]] || fail 'failed trusted classifier emitted a narrowing decision'

echo 'CI catalogue scope: Git, read failures and actual trusted-base workflow controls passed'
