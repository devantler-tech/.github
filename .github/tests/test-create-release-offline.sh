#!/usr/bin/env bash
# #348: catalogue release tests must execute without production write credentials.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
workflow="${1:-$root/.github/workflows/create-release.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$workflow" >"$work/workflow.json"
yq -o=json '.' "$ci" >"$work/ci.json"
jq -n --slurpfile w "$work/workflow.json" --slurpfile c "$work/ci.json" \
  '{workflow:$w[0],ci:$c[0]}' >"$work/bundle.json"
condition="\${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}"
guard() {
  jq -e --arg condition "$condition" '
    def runnable: .if == null and (.["continue-on-error"] // false) == false and
      (.shell == null or .shell == "bash") and .["working-directory"] == null;
    .workflow as $w | .ci as $c | $w.jobs["offline-test"] as $j |
    if $w.on.workflow_call.inputs["offline-test"].type != "boolean" or
      $w.on.workflow_call.inputs["offline-test"].default != false or
      $w.on.workflow_call.inputs["dry-run"].default != false or
      $w.on.workflow_call.secrets.APP_PRIVATE_KEY.required != false
    then error("offline-test must be default-off and secret-free")
    elif $w.jobs.release.if != "!inputs.offline-test"
    then error("offline-test must exclude the production release job")
    elif $j.if != "inputs.offline-test" or $j.needs != null or
      ($j["continue-on-error"] // false) != false
    then error("offline-test must execute independently")
    elif $w.permissions != {} or $j.permissions != {} or
      any($w.jobs[]; .permissions != null and .permissions != {}) or
      ([$j,$w.env // {}] | tostring | test("\\bsecrets\\b|create-github-app-token|github[.]token|GH_TOKEN|GITHUB_TOKEN|PRIVATE_KEY";"i"))
    then error("offline-test must request no permissions and no credentials")
    elif [$j.steps[] | select(.uses != null)] | length != 2
    then error("offline-test must use only hardening and Node setup")
    elif [$j.steps[] | select(.name == "📑 Download catalogue fixtures") |
      select(.if == null and (.["continue-on-error"] // false) == false and
        .["working-directory"] == "." and .shell == "bash" and
        .env.CATALOGUE_REPOSITORY == "${{ job.workflow_repository }}" and
        .env.CATALOGUE_SHA == "${{ job.workflow_sha }}" and
        (.run | contains("https://codeload.github.com/$CATALOGUE_REPOSITORY/tar.gz/$CATALOGUE_SHA")) and
        (.run | contains("env -i PATH=\"$PATH\" curl --disable --fail --silent --show-error --location")) and
        (.run | contains("--proto \u0027=https\u0027 --proto-redir \u0027=https\u0027")) and
        (.run | contains("--strip-components=1 --directory=.devantler-tech-actions")))] | length != 1
    then error("offline-test must download its immutable public workflow commit anonymously")
    elif ([$j.steps[] | select(.name == "🔎 Validate offline mode") |
      select(runnable and .env.DRY_RUN == "${{ inputs.dry-run }}" and
        (.run | contains("[[ \"$DRY_RUN\" == true ]]")) and (.run | contains("exit 1")))] | length) != 1
    then error("offline-test must require dry-run before executing")
    elif $j.defaults.run != {shell:"bash","working-directory":".devantler-tech-actions"} or
      ([$j.steps[] | select(.run == "bash .github/tests/create-release-fixture.sh") |
        select(runnable and .env.DISABLE_ISSUE_SIDE_EFFECTS == "${{ inputs.disable-issue-side-effects }}"
          and .env.WARN_MISSING_BREAKING_BANG == "${{ inputs.warn-missing-breaking-bang }}")] | length) != 1
    then error("offline release decisions must execute with the caller hook setting")
    elif (["test-create-release","test-create-release-no-issue-side-effects"] | all(. as $name |
      $c.jobs[$name].uses == "./.github/workflows/create-release.yaml" and
      $c.jobs[$name].with["offline-test"] == true and $c.jobs[$name].with["dry-run"] == true and
      $c.jobs[$name].secrets == null and $c.jobs[$name].permissions == {} and
      $c.jobs[$name].if == $condition and $c.jobs[$name].needs == null and
      ($c.jobs[$name]["continue-on-error"] // false) == false and
      ($c.jobs["ci-required-checks"].needs | index($name)) != null and
      any($c.jobs["ci-required-checks"].steps[]; (.env.JOB_RESULTS // "" |
        contains("needs."+$name+".result")) and (.run // "" | contains("$JOB_RESULTS"))))) | not
    then error("secret-free release calls must gate required CI")
    elif (["test-create-release-offline.sh","test-create-release-fixture-controls.sh"] | all(. as $script |
      [$c.jobs["test-create-release-config"].steps[] | select(.run == "bash .github/tests/"+$script)] |
        length == 1 and all(runnable))) | not
    then error("offline boundary regressions must execute in CI")
    else true end' "$1"
}
guard "$work/bundle.json" >/dev/null
[[ "${3:-}" != --guard-only ]] || exit 0
count=0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/bundle.json" >"$work/mutated.json"
  if guard "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
required secret	.workflow.on.workflow_call.secrets.APP_PRIVATE_KEY.required=true	secret-free
changed default	.workflow.on.workflow_call.inputs["offline-test"].default=true	default-off
consumer preview changed	.workflow.on.workflow_call.inputs["dry-run"].default=true	default-off
production execution	.workflow.jobs.release.if=null	exclude the production
skipped fixture	.workflow.jobs["offline-test"].if="false"	execute independently
fixture prerequisite	.workflow.jobs["offline-test"].needs="release"	execute independently
ignored failure	.workflow.jobs["offline-test"]["continue-on-error"]=true	execute independently
write permission	.workflow.jobs["offline-test"].permissions.contents="write"	no permissions
read permission breaks callers	.workflow.jobs["offline-test"].permissions.contents="read"	no permissions
workflow permission breaks callers	.workflow.permissions.contents="read"	no permissions
release job permission breaks callers	.workflow.jobs.release.permissions={contents:"read"}	no permissions
extra job permission breaks callers	.workflow.jobs.extra={permissions:{contents:"read"}}	no permissions
inherited permission	.workflow.jobs["offline-test"].permissions=null	no permissions
App key	.workflow.jobs["offline-test"].env.KEY="${{ secrets.APP_PRIVATE_KEY }}"	no credentials
bracket secret	.workflow.jobs["offline-test"].env.KEY="${{ secrets['APP_PRIVATE_KEY'] }}"	no credentials
uppercase secret	.workflow.jobs["offline-test"].env.KEY="${{ SECRETS.APP_PRIVATE_KEY }}"	no credentials
serialized secrets	.workflow.jobs["offline-test"].env.KEY="${{ toJSON(secrets) }}"	no credentials
App mint	.workflow.jobs["offline-test"].steps += [{uses:"actions/create-github-app-token@sha"}]	no credentials
token forwarding	.workflow.jobs["offline-test"].env.GH_TOKEN="${{ github.token }}"	no credentials
mutable source	.workflow.jobs["offline-test"].steps |= map(if .env.CATALOGUE_SHA then .env.CATALOGUE_SHA="main" else . end)	immutable public workflow commit
caller repository	.workflow.jobs["offline-test"].steps |= map(if .env.CATALOGUE_REPOSITORY then .env.CATALOGUE_REPOSITORY="${{ github.repository }}" else . end)	immutable public workflow commit
missing bootstrap directory	.workflow.jobs["offline-test"].steps |= map(if .env.CATALOGUE_SHA then .["working-directory"]=null else . end)	immutable public workflow commit
ambient curl config	.workflow.jobs["offline-test"].steps |= map(if .env.CATALOGUE_SHA then .run |= sub("curl --disable";"curl") else . end)	immutable public workflow commit
fixture bypass	.workflow.jobs["offline-test"].steps |= map(if .run == "bash .github/tests/create-release-fixture.sh" then .run="echo PASS" else . end)	decisions must execute
hook setting lost	.workflow.jobs["offline-test"].steps |= map(if .run then .env.DISABLE_ISSUE_SIDE_EFFECTS="true" else . end)	caller hook setting
warning setting lost	.workflow.jobs["offline-test"].steps |= map(if .run == "bash .github/tests/create-release-fixture.sh" then del(.env.WARN_MISSING_BREAKING_BANG) else . end)	caller hook setting
warning forced on	.workflow.jobs["offline-test"].steps |= map(if .run == "bash .github/tests/create-release-fixture.sh" then .env.WARN_MISSING_BREAKING_BANG="true" else . end)	caller hook setting
warning forced off	.workflow.jobs["offline-test"].steps |= map(if .run == "bash .github/tests/create-release-fixture.sh" then .env.WARN_MISSING_BREAKING_BANG="false" else . end)	caller hook setting
default App key	.ci.jobs["test-create-release"].secrets.APP_PRIVATE_KEY="key"	secret-free release calls
inherited secrets	.ci.jobs["test-create-release-no-issue-side-effects"].secrets="inherit"	secret-free release calls
live mode	.ci.jobs["test-create-release"].with["offline-test"]=false	secret-free release calls
write caller	.ci.jobs["test-create-release"].permissions.contents="write"	secret-free release calls
read caller masks compatibility	.ci.jobs["test-create-release"].permissions.contents="read"	secret-free release calls
lost aggregation	.ci.jobs["ci-required-checks"].needs |= map(select(. != "test-create-release"))	gate required CI
lost result	.ci.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-create-release.result";"needs.other.result") else . end)	gate required CI
boundary skipped	.ci.jobs["test-create-release-config"].steps |= map(if .run == "bash .github/tests/test-create-release-offline.sh" then .if="false" else . end)	regressions must execute
invalid offline mode	.workflow.jobs["offline-test"].steps |= map(select(.name != "🔎 Validate offline mode"))	require dry-run
behavior controls skipped	.ci.jobs["test-create-release-config"].steps |= map(select(.run != "bash .github/tests/test-create-release-fixture-controls.sh"))	regressions must execute
CASES
echo "PASS: release offline boundary rejects $count independent regressions"

# Execute the shipped retrieval block; only the external HTTP transport is replaced.
yq -r '.jobs.offline-test.steps[] | select(.name == "📑 Download catalogue fixtures") | .run' "$workflow" >"$work/download.sh"
mkdir "$work/download"
mkdir "$work/bin" "$work/source"
mkdir -p "$work/source/catalogue/.github/workflows" "$work/source/catalogue/.github/tests"
cp "$root/.github/workflows/create-release.yaml" "$work/source/catalogue/.github/workflows/"
cp "$root/.github/tests/create-release-fixture.sh" "$work/source/catalogue/.github/tests/"
cp "$root/.releaserc" "$work/source/catalogue/"
tar -czf "$work/valid.tar.gz" -C "$work/source" catalogue
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
fixture="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
[[ -z "${CURL_HOME-}${HTTPS_PROXY-}${GITHUB_TOKEN-}${GH_TOKEN-}" ]]
expected=(--disable --fail --silent --show-error --location
  --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 3
  --output "$fixture/catalogue.tar.gz"
  'https://codeload.github.com/devantler-tech/.github/tar.gz/0000000000000000000000000000000000000000')
[[ $# -eq ${#expected[@]} ]]
index=0
for argument in "$@"; do
  [[ "$argument" == "${expected[$index]}" ]]
  index=$((index + 1))
done
printf '%s\n' "$@" >"$fixture/request"
[[ "$(cat "$fixture/mode")" != failure ]] || exit 22
cp "$fixture/payload" "$fixture/catalogue.tar.gz"
CURL
chmod +x "$work/bin/curl"
printf '%s\n' failure >"$work/mode"
# Invalid metadata must fail before even the isolated recorder receives a request.
for invalid in repository short-sha mutable-ref path-sha uppercase-sha; do
  repository=devantler-tech/.github
  sha=0000000000000000000000000000000000000000
  case "$invalid" in
  repository) repository=example/other ;;
  short-sha) sha=abc123 ;;
  mutable-ref) sha=main ;;
  path-sha) sha=../../main ;;
  uppercase-sha) sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ;;
  esac
  if (cd "$work/download" && env -i PATH="$work/bin:$PATH" RUNNER_TEMP="$work" \
    CATALOGUE_REPOSITORY="$repository" CATALOGUE_SHA="$sha" bash -eo pipefail "$work/download.sh") >"$work/result" 2>&1; then
    echo "FAIL: invalid $invalid metadata was accepted" >&2
    exit 1
  fi
  grep -qF 'invalid catalogue source' "$work/result"
  [[ ! -e "$work/request" && ! -e "$work/catalogue.tar.gz" && ! -e "$work/download/.devantler-tech-actions" ]]
done
echo 'PASS: five invalid source inputs fail before download or extraction'

for transport in failure truncated missing-fixture valid; do
  rm -rf "$work/download/.devantler-tech-actions"
  rm -f "$work/catalogue.tar.gz" "$work/request"
  printf '%s\n' "$transport" >"$work/mode"
  case "$transport" in
  failure) ;;
  truncated) printf '%s\n' 'not a gzip archive' >"$work/payload" ;;
  missing-fixture)
    tar -czf "$work/payload" -C "$work/source" catalogue/.releaserc catalogue/.github/workflows
    ;;
  valid) cp "$work/valid.tar.gz" "$work/payload" ;;
  esac
  result=0
  (cd "$work/download" && env -i PATH="$work/bin:$PATH" RUNNER_TEMP="$work" \
    CATALOGUE_REPOSITORY=devantler-tech/.github CATALOGUE_SHA=0000000000000000000000000000000000000000 \
    CURL_HOME=fixture-curl-config HTTPS_PROXY=fixture-proxy GITHUB_TOKEN=fixture-token GH_TOKEN=fixture-token \
    bash -eo pipefail "$work/download.sh") >"$work/result" 2>&1 || result=$?
  grep -qxF 'https://codeload.github.com/devantler-tech/.github/tar.gz/0000000000000000000000000000000000000000' "$work/request"
  if [[ "$transport" == valid ]]; then
    [[ "$result" == 0 ]]
    cmp "$root/.releaserc" "$work/download/.devantler-tech-actions/.releaserc"
    cmp "$root/.github/tests/create-release-fixture.sh" "$work/download/.devantler-tech-actions/.github/tests/create-release-fixture.sh"
  else
    [[ "$result" != 0 ]] || {
      echo "FAIL: $transport source retrieval was accepted" >&2
      exit 1
    }
    [[ "$transport" != failure || ! -e "$work/download/.devantler-tech-actions" ]]
  fi
done
echo 'PASS: actual retrieval rejects failed, truncated and incomplete sources; valid files extract unchanged'
