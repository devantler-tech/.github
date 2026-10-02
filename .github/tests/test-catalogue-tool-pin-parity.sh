#!/usr/bin/env bash
# Compare executed production and negative-fixture roles, never stale comments.
set -euo pipefail
scope="${1:-all}"
ci="${2:-.github/workflows/ci.yaml}"
go_gate="${3:-.github/workflows/validate-go-project.yaml}"
lint_gate="${4:-.github/workflows/lint.yaml}"
fail() {
  echo "::error::$*" >&2
  exit 1
}
read_pin() {
  local file="$1" job="$2" id="$3" action="$4" pin count
  pin="$(JOB_ID="$job" STEP_ID="$id" yq -r '
    [.jobs[strenv(JOB_ID)].steps[]? | select(.id == strenv(STEP_ID)) | .uses // ""]
    | join("\n")' "$file")"
  count="$(JOB_ID="$job" yq -o=json '.jobs[strenv(JOB_ID)].steps' "$file" |
    jq -r --arg action "$action" '[.[]? | select((.uses // "") | startswith($action + "@"))] | length')"
  [[ "$pin" == "$action@"* && "${pin#"$action@"}" =~ ^[0-9a-f]{40}$ && "$count" == 1 ]] ||
    fail "$file/$job/$id must select exactly one full-SHA $action invocation"
  printf '%s\n' "$pin"
}
read_version() {
  JOB_ID="$2" STEP_ID="$3" yq -r '
    [.jobs[strenv(JOB_ID)].steps[]? | select(.id == strenv(STEP_ID)) | .with.version // ""]
    | join("\n")' "$1"
}
case "$scope" in all | golangci | megalinter) ;; *) fail 'unknown pin-parity scope' ;; esac
if [[ "$scope" == all || "$scope" == golangci ]]; then
  gate_pin="$(read_pin "$go_gate" golangci-lint golangci-lint golangci/golangci-lint-action)"
  fixture_pin="$(read_pin "$ci" test-validate-go-lint-blocks lint golangci/golangci-lint-action)"
  [[ "$gate_pin" == "$fixture_pin" ]] || fail 'production and failure-fixture golangci action pins differ'
  gate_version="$(read_version "$go_gate" golangci-lint golangci-lint)"
  fixture_version="$(read_version "$ci" test-validate-go-lint-blocks lint)"
  [[ -n "$gate_version" && "$gate_version" == "$fixture_version" ]] ||
    fail 'production and failure-fixture golangci tool versions differ or are missing'
  # The command is a behavioral contract, rather than a dependency version.
  yq -o=json '.' "$go_gate" | jq -e '
    [.jobs.test.steps[]? | select(.name == "🧪 Test")] as $test |
    ($test | length) == 1 and ($test[0].run | rtrimstr("\n")) == "go test ./..."' >/dev/null ||
    fail 'production test role must execute go test ./...'
  yq -o=json '.' "$ci" | jq -e '
    [.jobs["test-validate-go-test-blocks"].steps[]? | select(.id == "gotest")] as $test |
    ($test | length) == 1 and ($test[0].run | split("\n") |
      .[0] == "set -uo pipefail" and .[1] == "go test ./... 2>&1 | tee go-test-output.txt" and
      .[2] == "exit \"${PIPESTATUS[0]}\"")' >/dev/null ||
    fail 'negative test fixture must execute the real test command and preserve its exit status'
  echo 'PASS: production and failure-fixture golangci pins, tool versions and actual test roles agree'
fi
if [[ "$scope" == all || "$scope" == megalinter ]]; then
  fixture_pin="$(read_pin "$ci" test-lint-blocks ml oxsecurity/megalinter/flavors/go)"
  for gate in "$go_gate" "$lint_gate"; do
    gate_pin="$(read_pin "$gate" lint ml oxsecurity/megalinter/flavors/go)"
    [[ "$gate_pin" == "$fixture_pin" ]] || fail "$gate and test-lint-blocks use different MegaLinter pins"
  done
  echo 'PASS: both production gates and the failure fixture use the same complete MegaLinter pin'
fi
