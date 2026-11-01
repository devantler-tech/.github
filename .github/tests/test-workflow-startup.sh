#!/usr/bin/env bash
# Execute the shipped aggregate action's opt-in, build and evidence steps.
# Only the API transport is replaced; the real Go inspector decides each verdict.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
action="$root/actions/aggregate-job-checks/action.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/runner"
yq -o=json . "$action" >"$work/action.json"
jq -e '
  .inputs["check-workflow-startup"].default == "false" and
  .outputs["startup-clear"].value == "${{ steps.startup.outputs.clear }}" and
  .outputs["startup-receipt"].value == "${{ steps.startup.outputs.receipt }}" and
  (.runs.steps | length == 5) and
  .runs.steps[0].name == "📊 Summarize workflow result" and
  .runs.steps[1].id == "startup-admit" and
  ([.runs.steps[2:][] | .if] | all(. == "steps.startup-admit.outputs.enabled == '\''true'\''")) and
  (.runs.steps[2].uses | test("^actions/setup-go@[a-f0-9]{40}$")) and
  .runs.steps[2].with.cache == false and
  .runs.steps[2].with["go-version-file"] == "${{ github.action_path }}/../../.github/scripts/check-ci-run-budget/go.mod" and
  .runs.steps[3].id == "startup-build" and
  .runs.steps[3].env == {GOWORK:"off",GOFLAGS:"",GOTOOLCHAIN:"local",CGO_ENABLED:"0"} and
  .runs.steps[4].id == "startup" and
  .runs.steps[4].env.HEAD_SHA == "${{ github.event.pull_request.head.sha || github.sha }}" and
  .runs.steps[4].env.REPOSITORY == "${{ github.repository }}" and
  .runs.steps[4].env.RUN_ID == "${{ github.run_id }}" and
  .runs.steps[4].env.RUN_ATTEMPT == "${{ github.run_attempt }}" and
  .runs.steps[4].env.EVENT_NAME == "${{ github.event_name }}" and
  .runs.steps[4].env.GH_TOKEN == "${{ inputs.github-token || github.token }}" and
  ([.runs.steps[] | .["continue-on-error"]] | all(. == null or . == false))
' "$work/action.json" >/dev/null
yq -o=json '.jobs.test-aggregate-job-checks-unknown' "$root/.github/workflows/ci.yaml" >"$work/job.json"
jq -e '
  .permissions == {contents:"read",actions:"read"} and
  ([.steps[] | select(.name == "Verify native workflow startup snapshot")
    | select(.uses == "$/actions/aggregate-job-checks"
      and .with["check-workflow-startup"] == "true"
      and (.if == null or .if == true)
      and (.["continue-on-error"] == null or .["continue-on-error"] == false))] | length == 1) and
  ([.steps[] | select(.run == "bash .github/tests/test-workflow-startup.sh")
    | select((.if == null or .if == true)
      and (.["continue-on-error"] == null or .["continue-on-error"] == false))] | length == 1)
' "$work/job.json" >/dev/null
go -C "$root/.github/scripts/check-ci-run-budget" test -race ./...
go -C "$root/.github/scripts/check-ci-run-budget" vet ./...
for id in startup-admit startup-build startup; do
  yq -r ".runs.steps[] | select(.id == \"$id\") | .run" "$action" >"$work/$id.sh"
done
for enabled in '' false; do
  ENABLED="$enabled" GITHUB_OUTPUT="$work/off" bash "$work/startup-admit.sh"
  [[ "$(cat "$work/off")" == enabled=false ]]
  rm "$work/off"
done
if ENABLED=invalid GITHUB_OUTPUT="$work/invalid" bash "$work/startup-admit.sh" >/dev/null 2>&1; then
  echo 'invalid startup opt-in was admitted' >&2
  exit 1
fi
[[ ! -e "$work/invalid" ]]
ENABLED=true GITHUB_OUTPUT="$work/on" bash "$work/startup-admit.sh"
[[ "$(cat "$work/on")" == enabled=true ]]
export RUNNER_TEMP="$work/runner" GITHUB_ACTION_PATH="$root/actions/aggregate-job-checks"
GOWORK=off GOFLAGS='' GOTOOLCHAIN=local CGO_ENABLED=0 GITHUB_OUTPUT="$work/build" bash "$work/startup-build.sh"
compiled="$(sed -n 's/^binary=//p' "$work/build")"
[[ "$compiled" == "$RUNNER_TEMP"/workflow-startup.*/inspector && -f "$compiled" ]]
cp "$compiled" "$work/inspector"
rm -rf "${compiled%/*}"

cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 7 && "$1" == api && "$2" == --hostname && "$3" == github.com &&
  "$4" == --method && "$5" == GET && "$6" == -- ]] || exit 99
printf '%s\n' "$7" >> "$STARTUP_CALLS"
case "$7" in
  repos/example/repo/actions/runs/42) cat "$STARTUP_FIXTURE/current.json" ;;
  'repos/example/repo/actions/runs?head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&per_page=100&page=1')
    cat "$STARTUP_FIXTURE/runs.json" ;;
  'repos/example/repo/actions/runs/100/attempts/1/jobs?per_page=100&page=1')
    printf '%s\n' '{"total_count":0,"jobs":[]}' ;;
  *) exit 98 ;;
esac
if [[ "$STARTUP_SCENARIO" == read-error ]]; then
  echo 'PRIVATE_API_SENTINEL' >&2
  exit 17
fi
SH
chmod +x "$work/bin/gh"
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat >"$work/bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STARTUP_SCENARIO:-}" == serialization-error && "$#" == 3 && "$1" == -c && "$2" == . ]]; then
  echo 'PRIVATE_SERIALIZATION_SENTINEL'
  exit 17
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$work/bin/jq"
export PATH="$work/bin:$PATH" STARTUP_FIXTURE="$work" STARTUP_CALLS="$work/calls"
startup_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' '{"id":42,"workflow_id":1,"run_number":1,"run_attempt":1,"repository":{"full_name":"example/repo"},"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","event":"pull_request","head_branch":"feature","pull_requests":[{"number":7}],"status":"in_progress","conclusion":null}' >"$work/current.json"

# Each case executes the production check step and requires its actual reason,
# never merely a nonzero exit that a broken fixture could also produce.
for scenario in clear startup-failure no-jobs read-error serialization-error invalid-head; do
  expected=0 state=clear reason=no_observed_startup_failure
  conclusion=startup_failure
  case "$scenario" in
  startup-failure)
    expected=1
    state=blocked
    reason=workflow_startup_failed
    ;;
  no-jobs)
    expected=1
    state=blocked
    reason=workflow_failed_without_jobs
    conclusion=failure
    ;;
  read-error)
    expected=2
    state=unknown
    reason=current_run_unverified
    ;;
  serialization-error) expected=17 ;;
  invalid-head)
    expected=2
    state=unknown
    reason=invalid_arguments
    ;;
  esac
  if [[ "$scenario" == startup-failure || "$scenario" == no-jobs ]]; then
    jq -n --slurpfile current "$work/current.json" --arg head "$startup_head" --arg verdict "$conclusion" '{
      total_count:2, workflow_runs:[$current[0],{
        id:100,workflow_id:2,run_number:2,run_attempt:1,repository:{full_name:"example/repo"},
        head_sha:$head,event:"pull_request",head_branch:"feature",pull_requests:[{number:7}],
        status:"completed",conclusion:$verdict
      }]
    }' >"$work/runs.json"
  else
    jq -n --slurpfile current "$work/current.json" '{total_count:1,workflow_runs:$current}' >"$work/runs.json"
  fi
  scratch="$(mktemp -d "$RUNNER_TEMP/workflow-startup.XXXXXX")"
  cp "$work/inspector" "$scratch/inspector"
  : >"$STARTUP_CALLS"
  rm -f "$work/outputs"
  selected_head="$startup_head"
  if [[ "$scenario" == invalid-head ]]; then selected_head=invalid; fi
  code=0
  check_env=(
    "STARTUP_SCENARIO=$scenario" "REPOSITORY=example/repo" "HEAD_SHA=$selected_head"
    "RUN_ID=42" "RUN_ATTEMPT=1" "EVENT_NAME=pull_request"
    "BINARY=$scratch/inspector" "GITHUB_OUTPUT=$work/outputs"
  )
  env "${check_env[@]}" bash "$work/startup.sh" >"$work/result" 2>&1 || code=$?
  [[ "$code" == "$expected" ]] || {
    echo "unexpected exit for $scenario: $code" >&2
    cat "$work/result" >&2
    exit 1
  }
  jq -e --arg state "$state" --arg reason "$reason" '
    .scope == "head_workflow_startup_snapshot" and .state == $state and .reason == $reason
  ' "$work/result" >/dev/null
  if grep -q 'PRIVATE_.*SENTINEL' "$work/result"; then
    echo 'private producer data escaped into the receipt' >&2
    exit 1
  fi
  if [[ "$scenario" == clear ]]; then
    grep -q '^clear=true$' "$work/outputs"
    grep -q '^receipt={' "$work/outputs"
  else
    [[ ! -e "$work/outputs" ]]
  fi
  if [[ "$scenario" == invalid-head ]]; then [[ ! -s "$STARTUP_CALLS" ]]; fi
  [[ ! -d "$scratch" ]]
done
printf 'PASS: shipped startup steps bind native context, default off and fail closed\n'
