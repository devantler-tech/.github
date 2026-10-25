#!/usr/bin/env bash
# Bind the retired wrapper's complete fixture coverage to native catalogue jobs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ ! -e "$root/.github/workflows/run-dotnet-tests.yaml" ]] || {
  echo 'FAIL: singleton .NET workflow is still exported' >&2
  exit 1
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
      ([.steps[] | select(.uses=="$/.github/actions/test-dotnet-fixture")] | length==1 and all(.if==null and .["continue-on-error"]==null and .with["working-directory"]==".github/fixtures/run-dotnet-tests" and
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
    .runs.steps[0].uses==null and .runs.steps[0].if==null and
    .runs.steps[0].env=={FIXTURE_ACTION_SOURCE:"${{ github.action_path }}",FIXTURE_WORKSPACE:"${{ github.workspace }}"} and
    (.runs.steps[0].run|contains("fixture_source_dir")) and
    .runs.steps[1].id=="github-source-before" and
    .runs.steps[1].if=="${{ inputs.github-token != '\'''\'' }}" and
    .runs.steps[2].uses=="$/actions/run-dotnet-tests" and
    .runs.steps[2].if==null and .runs.steps[2].with["github-token"]=="${{ inputs.github-token }}" and
    .runs.steps[3].if=="${{ inputs.github-token != '\'''\'' }}" and
    .runs.steps[3].env.BEFORE_STATE=="${{ steps.github-source-before.outputs.state }}" and
    (.runs.steps[3].run|contains("if [[ \"$after_state\" != \"$BEFORE_STATE\" ]]; then")) and
    all(.runs.steps[]; .["continue-on-error"]==null)
  ' "$1" >/dev/null
}
yq -o=json . "$ci" >"$work/ci.json"
yq -o=json . "$action" >"$work/action.json"
# Bind fixture provisioning to the real shared action. A floating channel can
# resolve a version before its download exists, so every installed SDK is exact.
check_sdks() {
  jq -e --slurpfile sdk_action "$2" '
    def setup: select((.uses // "") | startswith("actions/setup-dotnet@"));
    def full_pin: (.uses // "") | test("^actions/setup-dotnet@[0-9a-f]{40}$");
    def versions: .with["dotnet-version"] | tostring | split("\n") | map(select(length>0));
    def mandatory: .if==null and .["continue-on-error"]==null;
    [$sdk_action[0].runs.steps[] | setup] as $shared |
    [$sdk_action[0].runs.steps[] | select(.id=="sdk-check")] as $probe |
    [.jobs["test-run-dotnet-tests-preserves-source-mapping"].steps[] | setup] as $mapping |
    [.jobs["test-run-dotnet-tests-blocks"].steps[] | setup] as $blocks |
    ($shared[0]|versions) as $versions |
    ($shared|length)==1 and ($mapping|length)==1 and ($blocks|length)==1 and
    all($shared[]; full_pin) and all($mapping[]; full_pin) and all($blocks[]; full_pin) and
    $shared[0].if=="steps.sdk-check.outputs.install-needed != '\''false'\''" and
    $shared[0]["continue-on-error"]==null and
    ($probe|length)==1 and ($probe[0]|mandatory) and $probe[0].shell=="bash" and
    ($probe[0].env.SDK_VERSIONS|tostring|split("\n")|map(select(length>0)))==$versions and ($mapping[0]|mandatory) and ($blocks[0]|mandatory) and
    ($versions|length)==2 and
    ($versions[0]|test("^9[.]0[.][0-9]+$")) and
    ($versions[1]|test("^10[.]0[.][0-9]+$")) and
    ($mapping[0]|versions)==[$versions[1]] and
    ($blocks[0]|versions)==$versions
  ' "$1" >/dev/null
}
yq -o=json . "$root/actions/run-dotnet-tests/action.yaml" >"$work/sdk.json"
check_sdks "$work/ci.json" "$work/sdk.json" || {
  echo 'FAIL: .NET SDKs must be exact released-generation pins with complete fixture lockstep' >&2
  exit 1
}
sdk_controls=0
for mutation in \
  '.runs.steps[1].with["dotnet-version"]="9\n10"' \
  '.runs.steps[1].with["dotnet-version"]="9.0.x\n10.0.x"' \
  '.runs.steps[1].with["dotnet-version"]="9.0.319"' \
  '.runs.steps[1].with["dotnet-version"]="10.0.402"' \
  '.runs.steps[1].with["dotnet-version"]="9.0.319\n10.0.402-preview.1"' \
  '.runs.steps[0].env.SDK_VERSIONS="9.0.319"' \
  '.runs.steps[0].if="false"' \
  'del(.runs.steps[0])' \
  '.runs.steps[1].if="false"' \
  '.runs.steps[1]["continue-on-error"]=true' \
  'del(.runs.steps[1])' \
  '.runs.steps += [.runs.steps[1]]' \
  '.runs.steps += [(.runs.steps[1] | .uses="actions/setup-dotnet@v4")]'; do
  jq "$mutation" "$work/sdk.json" >"$work/broken-sdk.json"
  if check_sdks "$work/ci.json" "$work/broken-sdk.json"; then
    echo 'FAIL: accepted floating, incomplete or bypassed SDK provisioning' >&2
    exit 1
  fi
  sdk_controls=$((sdk_controls + 1))
done
for mutation in \
  '.jobs["test-run-dotnet-tests-preserves-source-mapping"].steps |= map(if (.uses // "" | startswith("actions/setup-dotnet@")) then .with["dotnet-version"]="10" else . end)' \
  '.jobs["test-run-dotnet-tests-blocks"].steps |= map(select((.uses // "" | startswith("actions/setup-dotnet@")) | not))' \
  '.jobs["test-run-dotnet-tests-blocks"].steps |= map(if (.uses // "" | startswith("actions/setup-dotnet@")) then .with["dotnet-version"]="9.0.318\n10.0.402" else . end)' \
  '.jobs["test-run-dotnet-tests-preserves-source-mapping"].steps += [{uses:"actions/setup-dotnet@v4",with:{"dotnet-version":"10.0.402"}}]' \
  '.jobs["test-run-dotnet-tests-blocks"].steps += [{uses:"actions/setup-dotnet@v4",with:{"dotnet-version":"9.0.319\n10.0.402"}}]'; do
  jq "$mutation" "$work/ci.json" >"$work/broken-sdk-ci.json"
  if check_sdks "$work/broken-sdk-ci.json" "$work/sdk.json"; then
    echo 'FAIL: accepted missing, floating or mismatched fixture SDKs' >&2
    exit 1
  fi
  sdk_controls=$((sdk_controls + 1))
done
# Execute the actual selection step against complete and refused SDK listings.
yq -r '.runs.steps[] | select(.id=="sdk-check") | .run' "$root/actions/run-dotnet-tests/action.yaml" >"$work/sdk-probe.sh"
yq -r '.runs.steps[] | select(.id=="sdk-check") | .env.SDK_VERSIONS' "$root/actions/run-dotnet-tests/action.yaml" >"$work/sdk-versions"
mkdir -p "$work/sdk-bin"
cat >"$work/sdk-bin/dotnet" <<'DOTNET'
#!/usr/bin/env bash
[[ "$*" == --list-sdks ]] || exit 91
printf '%s' "$SDK_LISTING"
exit "$SDK_LIST_EXIT"
DOTNET
chmod +x "$work/sdk-bin/dotnet"
probe_case() {
  local name=$1 expected=$2 listing=$3 result=$4
  : >"$work/sdk-output"
  DOTNET_INSTALL_DIR='' SDK_LISTING="$listing" SDK_LIST_EXIT="$result" SDK_VERSIONS="$(cat "$work/sdk-versions")" \
  GITHUB_OUTPUT="$work/sdk-output" PATH="$work/sdk-bin:$PATH" bash "$work/sdk-probe.sh"
  grep -qx "install-needed=$expected" "$work/sdk-output" || {
    echo "FAIL: SDK listing $name misclassified" >&2
    exit 1
  }
}
first=$(sed -n '1p' "$work/sdk-versions")
second=$(sed -n '2p' "$work/sdk-versions")
complete="$first [/fixture/sdk]"$'\n'"$second [/fixture/sdk]"
probe_case exact false "$complete" 0
probe_case missing true '' 0
probe_case missing_previous true "$second [/fixture/sdk]" 0
probe_case missing_current true "$first [/fixture/sdk]" 0
probe_case near_miss true "$first"'0 [/fixture/sdk]'$'\n'"$second [/fixture/sdk]" 0
probe_case partial_failure true "$complete" 19
: >"$work/sdk-output"
DOTNET_INSTALL_DIR="$work/custom-sdk" SDK_LISTING="$complete" SDK_LIST_EXIT=0 SDK_VERSIONS="$(cat "$work/sdk-versions")" \
GITHUB_OUTPUT="$work/sdk-output" PATH="$work/sdk-bin:$PATH" bash "$work/sdk-probe.sh"
grep -qx 'install-needed=true' "$work/sdk-output" || {
  echo 'FAIL: explicit install directory bypassed setup' >&2
  exit 1
}
: >"$work/sdk-output"
if SDK_VERSIONS='' GITHUB_OUTPUT="$work/sdk-output" PATH="$work/sdk-bin:$PATH" bash "$work/sdk-probe.sh"; then
  echo 'FAIL: actual SDK probe accepted missing requirements' >&2
  exit 1
fi
[[ ! -s "$work/sdk-output" ]] || {
  echo 'FAIL: invalid requirements published output' >&2
  exit 1
}
echo "PASS: exact SDK provisioning and $sdk_controls refusal controls"
check_ci "$work/ci.json" || {
  echo 'FAIL: native OS, token or fixture binding changed' >&2
  exit 1
}
check_action "$work/action.json" || {
  echo 'FAIL: source-state comparison or real action binding changed' >&2
  exit 1
}
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
    jq --arg id "$id" ".jobs[\$id] |= ($mutation)" "$work/ci.json" >"$work/broken.json"
    if check_ci "$work/broken.json"; then
      echo "FAIL: accepted native fixture mutation $id" >&2
      exit 1
    fi
    controls=$((controls + 1))
  done
done
for mutation in \
  '.runs.steps[0].run="echo skipped"' \
  '.runs.steps[0].if="false"' \
  '.runs.steps[0].env.FIXTURE_ACTION_SOURCE="candidate"' \
  '.runs.steps[1].if="false"' \
  '.runs.steps[2].if="false"' \
  '.runs.steps[2].uses="./another-action"' \
  ".runs.steps[2].with[\"github-token\"]=\"\${{ github.token }}\"" \
  '.runs.steps[3].run="echo unchanged"' \
  '.runs.steps[3].env.BEFORE_STATE=""' \
  '.runs.steps[3]["continue-on-error"]=true'; do
  jq "$mutation" "$work/action.json" >"$work/broken.json"
  if check_action "$work/broken.json"; then
    echo 'FAIL: accepted source-state or token regression' >&2
    exit 1
  fi
  controls=$((controls + 1))
done
# Execute the actual isolation guard with a separate native action cache and
# reject the former workspace-relative source placement, not just its spelling.
mkdir -p "$work/action-cache" "$work/consumer/actions/inside"
yq -r '.runs.steps[0].run' "$action" >"$work/isolation.sh"
FIXTURE_ACTION_SOURCE="$work/action-cache" FIXTURE_WORKSPACE="$work/consumer" \
  bash "$work/isolation.sh"
if FIXTURE_ACTION_SOURCE="$work/consumer/actions/inside" FIXTURE_WORKSPACE="$work/consumer" \
  bash "$work/isolation.sh" >"$work/isolation-failure" 2>&1; then
  echo 'FAIL: native action source may pollute the consumer workspace' >&2
  exit 1
fi
grep -q 'Native action source entered the consumer workspace' "$work/isolation-failure"
echo "PASS: both native .NET fixture jobs and $controls refusal controls"
