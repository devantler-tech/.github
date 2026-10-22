#!/usr/bin/env bash
# Bind the retired wrapper's complete fixture coverage to native catalogue jobs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ ! -e "$root/.github/workflows/run-dotnet-tests.yaml" ]] || {
  echo 'FAIL: singleton .NET workflow is still exported' >&2; exit 1;
}
ci="$root/.github/workflows/ci.yaml"
action="$root/.github/actions/test-dotnet-fixture/action.yaml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Read parsed workflow data, never evaluate candidate expressions as shell commands.
check_ci() {
  jq -e '
    def compact: gsub("[[:space:]]";"");
    .jobs as $jobs |
    ["test-run-dotnet-tests-workflow", "test-run-dotnet-tests-workflow-authenticated"] |
    all(. as $id | $jobs[$id] |
      .uses == null and .["runs-on"] == "${{ matrix.os }}" and
      .["continue-on-error"]==null and
      .strategy.matrix.os == ["ubuntu-latest","windows-latest","macos-latest"] and
      .permissions == {contents:"read",packages:"read","code-quality":"write"} and
      ([.steps[] | select((.uses // "") | startswith("actions/checkout@"))] | length==1 and all(.with["persist-credentials"]==false)) and
      ([.steps[] | select(.uses=="./.github/actions/test-dotnet-fixture")] | length==1 and all(.if==null and .["continue-on-error"]==null and .with["working-directory"]==".github/fixtures/run-dotnet-tests" and
        (.with["github-token"] | compact) == (if $id=="test-run-dotnet-tests-workflow" then
          "${{ github.event_name != '\''pull_request'\'' && secrets.GITHUB_TOKEN || '\'''\'' }}"
        else
          "${{ (github.event_name != '\''pull_request'\'' || (github.event.pull_request.head.repo.full_name == github.repository && !endsWith(github.event.pull_request.user.login, '\''[bot]'\''))) && secrets.GITHUB_TOKEN || '\'''\'' }}"
        end | compact)))
    )
  ' "$1" >/dev/null
}
# Source-state checks must surround the actual action and use the saved snapshot.
check_action() {
  jq -e '
    .runs.using=="composite" and
    (.runs.steps|length)==4 and
    .runs.steps[0].with.repository=="${{ job.workflow_repository }}" and
    .runs.steps[0].with.ref=="${{ job.workflow_sha }}" and
    .runs.steps[0].with.path==".devantler-tech-actions" and
    .runs.steps[0].with["sparse-checkout"]=="/actions/run-dotnet-tests/" and
    .runs.steps[0].with["sparse-checkout-cone-mode"]==false and
    .runs.steps[0].with["persist-credentials"]==false and
    .runs.steps[1].id=="github-source-before" and
    .runs.steps[1].if=="${{ inputs.github-token != '\'''\'' }}" and
    .runs.steps[2].uses=="./.devantler-tech-actions/actions/run-dotnet-tests" and
    .runs.steps[2].if==null and .runs.steps[2].with["github-token"]=="${{ inputs.github-token }}" and
    .runs.steps[3].if=="${{ inputs.github-token != '\'''\'' }}" and
    .runs.steps[3].env.BEFORE_STATE=="${{ steps.github-source-before.outputs.state }}" and
    (.runs.steps[3].run|contains("if [[ \"$after_state\" != \"$BEFORE_STATE\" ]]; then")) and
    all(.runs.steps[]; .["continue-on-error"]==null)
  ' "$1" >/dev/null
}
yq -o=json . "$ci" > "$work/ci.json"
yq -o=json . "$action" > "$work/action.json"
check_ci "$work/ci.json" || { echo 'FAIL: native OS, token or fixture binding changed' >&2; exit 1; }
check_action "$work/action.json" || { echo 'FAIL: source-state comparison or real action binding changed' >&2; exit 1; }
controls=0
for id in test-run-dotnet-tests-workflow test-run-dotnet-tests-workflow-authenticated; do
  for mutation in \
    '.strategy.matrix.os=["ubuntu-latest"]' \
    '.permissions.packages="write"' \
    '.["continue-on-error"]=true' \
    '.steps[1].with["persist-credentials"]=true' \
    ".steps[-1].with[\"github-token\"]=\"\${{ secrets.GITHUB_TOKEN }}\"" \
    '.steps[-1].if="false"' \
    '.steps[-1]["continue-on-error"]=true' \
    '.steps[-1].uses="./another-action"'; do
    jq --arg id "$id" ".jobs[\$id] |= ($mutation)" "$work/ci.json" > "$work/broken.json"
    if check_ci "$work/broken.json"; then echo "FAIL: accepted native fixture mutation $id" >&2; exit 1; fi
    controls=$((controls+1))
  done
done
for mutation in \
  '.runs.steps[0].with.ref="main"' \
  'del(.runs.steps[0].with["sparse-checkout"])' \
  '.runs.steps[0].with["persist-credentials"]=true' \
  '.runs.steps[1].if="false"' \
  '.runs.steps[2].if="false"' \
  '.runs.steps[2].uses="./another-action"' \
  ".runs.steps[2].with[\"github-token\"]=\"\${{ github.token }}\"" \
  '.runs.steps[3].run="echo unchanged"' \
  '.runs.steps[3].env.BEFORE_STATE=""' \
  '.runs.steps[3]["continue-on-error"]=true'; do
  jq "$mutation" "$work/action.json" > "$work/broken.json"
  if check_action "$work/broken.json"; then echo 'FAIL: accepted source-state or token regression' >&2; exit 1; fi
  controls=$((controls+1))
done
echo "PASS: both native .NET fixture jobs and $controls refusal controls"
