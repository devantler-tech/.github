#!/usr/bin/env bash
# Exercise shipped action steps and native Go/CLI refusal paths without network.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
action="$root/actions/check-ci-run-budget/action.yaml"
[[ -f "$action" ]] || { echo 'CI run budget action is missing' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/runner"
yq -o=json . "$action" > "$work/action.json"
jq -e '
  .inputs.enabled.default == "false" and
  .outputs.validated.value == "${{ steps.check.outputs.validated }}" and
  .outputs.receipt.value == "${{ steps.check.outputs.receipt }}" and
  (.runs.steps | length == 4) and
  (.runs.steps[0].id == "admit") and
  ([.runs.steps[1:][] | .if] | all(. == "steps.admit.outputs.enabled == '\''true'\''")) and
  (.runs.steps[1].uses | test("^actions/setup-go@[a-f0-9]{40}$")) and
  .runs.steps[1].with.cache == false and
  .runs.steps[1].with["go-version-file"] == "${{ github.action_path }}/../../.github/scripts/check-ci-run-budget/go.mod" and
  .runs.steps[2].env == {GOWORK:"off",GOFLAGS:"",GOTOOLCHAIN:"local",CGO_ENABLED:"0"} and
  .runs.steps[2].id == "build" and
  .runs.steps[3].id == "check" and
  .runs.steps[3].env.GH_TOKEN == "${{ inputs.github-token || github.token }}" and
  ([.runs.steps[] | .["continue-on-error"]] | all(. == null or . == false))
' "$work/action.json" >/dev/null
for id in admit build check; do
  yq -r ".runs.steps[] | select(.id == \"$id\") | .run" "$action" > "$work/$id.sh"
done
for enabled in '' false; do
  ENABLED="$enabled" GITHUB_OUTPUT="$work/off" bash "$work/admit.sh"
  [[ "$(cat "$work/off")" == enabled=false ]]
  rm "$work/off"
done
if ENABLED=invalid GITHUB_OUTPUT="$work/invalid" bash "$work/admit.sh" >/dev/null 2>&1; then
  echo 'invalid flag was admitted' >&2; exit 1
fi
[[ ! -e "$work/invalid" ]]
go -C "$root/.github/scripts/check-ci-run-budget" test -race -cover ./...
go -C "$root/.github/scripts/check-ci-run-budget" vet ./...
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 7 && "$1" == api && "$2" == --hostname && "$3" == github.com &&
  "$4" == --method && "$5" == GET && "$6" == -- ]] || exit 99
case "$7" in
  repos/example/repo/actions/runs/42) cat "$BUDGET_FIXTURE/run.json" ;;
  'repos/example/repo/actions/runs/42/jobs?filter=latest&per_page=100&page=1') cat "$BUDGET_FIXTURE/jobs.json" ;;
  *) exit 98 ;;
esac
if [[ "${FAIL_METADATA:-false}" == true ]]; then exit 17; fi
SH
chmod +x "$work/bin/gh"
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat > "$work/bin/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_RECEIPT_SERIALIZATION:-false}" == true && "$#" == 3 && "$1" == -c && "$2" == . ]]; then
  exit 17
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$work/bin/jq"
export PATH="$work/bin:$PATH" BUDGET_FIXTURE="$work"
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' '{"id":42,"run_attempt":1,"repository":{"full_name":"example/repo"},"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","path":".github/workflows/ci.yaml","event":"pull_request","status":"completed","conclusion":"success","created_at":"2020-01-01T00:00:00Z","updated_at":"2020-01-02T00:00:00Z"}' > "$work/run.json"
for scenario in below at above failed-read failed-serialization; do
  case "$scenario" in
    below|failed-read|failed-serialization) end=00:14:59; expected=within_budget; code=0 ;;
    at) end=00:15:00; expected=over_budget; code=1 ;;
    above) end=00:15:01; expected=over_budget; code=1 ;;
  esac
  fail_metadata=false
  fail_serialization=false
  if [[ "$scenario" == failed-read ]]; then fail_metadata=true; expected=unknown; code=2; fi
  if [[ "$scenario" == failed-serialization ]]; then fail_serialization=true; code=17; fi
  printf '{"total_count":1,"jobs":[{"id":1,"run_id":42,"run_attempt":1,"head_sha":"%s","status":"completed","conclusion":"success","started_at":"2020-01-01T00:01:00Z","completed_at":"2020-01-01T%sZ"}]}\n' "$head" "$end" > "$work/jobs.json"
  ENABLED=true GITHUB_OUTPUT="$work/on" bash "$work/admit.sh"
  [[ "$(cat "$work/on")" == enabled=true ]]
  rm "$work/on"
  GITHUB_ACTION_PATH="$root/actions/check-ci-run-budget" RUNNER_TEMP="$work/runner" GITHUB_OUTPUT="$work/build-output" \
    GOWORK=off GOFLAGS="" GOTOOLCHAIN=local CGO_ENABLED=0 bash "$work/build.sh"
  binary="$(sed -n 's/^binary=//p' "$work/build-output")"
  rm "$work/build-output"
  actual=0
  BINARY="$binary" REPOSITORY=example/repo RUN_ID=42 RUN_ATTEMPT=1 HEAD_SHA="$head" \
    WORKFLOW_PATH=.github/workflows/ci.yaml EVENT_NAME=pull_request FAIL_METADATA="$fail_metadata" \
    FAIL_RECEIPT_SERIALIZATION="$fail_serialization" \
    RUNNER_TEMP="$work/runner" GITHUB_OUTPUT="$work/validated" \
    bash "$work/check.sh" > "$work/receipt.json" || actual=$?
  if [[ "$actual" != "$code" ]]; then
    printf '%s: expected action exit %s, got %s\n' "$scenario" "$code" "$actual" >&2
    exit 1
  fi
  jq -e --arg state "$expected" '.scope == "single_workflow_run" and .state == $state' "$work/receipt.json" >/dev/null
  [[ ! -e "$binary" ]]
  [[ ! -e "${binary%/*}" ]]
  if [[ "$code" == 0 ]]; then
    grep -qx 'validated=true' "$work/validated"
    published_receipt="$(sed -n 's/^receipt=//p' "$work/validated")"
    [[ -n "$published_receipt" && "$published_receipt" == "$(jq -c . "$work/receipt.json")" ]]
    rm "$work/validated"
  else
    [[ ! -e "$work/validated" ]]
  fi
done
echo 'PASS: disabled, enabled, exact deadline, native read-failure and output-serialization paths'
