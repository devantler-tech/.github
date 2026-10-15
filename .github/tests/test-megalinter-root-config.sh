#!/usr/bin/env bash
# The native cases prove loader/checker behavior; this guard pins the actual
# production bindings independently of its synthetic configuration.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for role in lint validate-go-project validate-go-project-readonly; do
  yq -o=json '.' "$root/.github/workflows/$role.yaml" >"$scratch/$role.json"
done
jq -s '.' "$scratch/lint.json" "$scratch/validate-go-project.json" "$scratch/validate-go-project-readonly.json" >"$scratch/actual.json"
admit() {
  jq -e 'length == 3 and all(.[];
    [.jobs.lint.steps[] | select(.id == "ml")] as $steps |
    ($steps | length) == 1 and
    (["${{ github.workspace }}/.mega-linter.yml", "/github/workspace/.mega-linter.yml"] |
      index($steps[0].env.MEGALINTER_CONFIG) != null))' "$1" >/dev/null
}
if ! admit "$scratch/actual.json"; then
  echo 'TEST FAIL -- MegaLinter must read repository-root configuration through its container mount' >&2
  exit 1
fi
count=0
for role in 0 1 2; do
  for value in 'missing' 'host' 'relative' 'nested'; do
    jq --argjson role "$role" --arg value "$value" '
      (.[ $role ].jobs.lint.steps[] | select(.id == "ml") | .env.MEGALINTER_CONFIG) =
        (if $value == "missing" then null
         elif $value == "host" then "/home/unrelated/.mega-linter.yml"
         elif $value == "relative" then ".mega-linter.yml"
         else "/github/workspace/server/.mega-linter.yml" end)' "$scratch/actual.json" >"$scratch/mutant.json"
    if cmp -s "$scratch/actual.json" "$scratch/mutant.json" || admit "$scratch/mutant.json"; then
      echo "TEST FAIL -- configuration binding mutation admitted: $role/$value" >&2
      exit 1
    fi
    count=$((count + 1))
  done
done
yq -o=json '.jobs["test-lint-blocks"]' "$root/.github/workflows/ci.yaml" >"$scratch/native.json"
native_admit() {
  jq -e '
    . as $job |
    ["root","nested","absent","malformed","finding"] as $cases |
    .permissions == {contents:"read"} and .["runs-on"] == "ubuntu-latest" and
    (has("strategy") | not) and
    ([.steps[] | select(.id != null) | .id] ==
      [$cases[] | "prepare-" + ., "ml-" + ., "assert-" + .]) and
    all($cases[]; . as $case |
      [$job.steps[] | select(.id == "prepare-" + $case)] as $prepare |
      [$job.steps[] | select(.id == "ml-" + $case)] as $action |
      [$job.steps[] | select(.id == "assert-" + $case)] as $assert |
      ($prepare | length) == 1 and ($action | length) == 1 and ($assert | length) == 1 and
      $prepare[0].run == "bash .github/tests/megalinter-config-container.sh prepare" and
      $prepare[0].env.SCENARIO == $case and
      $prepare[0].if == "${{ !cancelled() }}" and
      ($prepare[0] | has("continue-on-error") | not) and
      $action[0].if == ("${{ !cancelled() && steps.prepare-" + $case + ".outcome == '\''success'\'' }}") and
      $action[0]["continue-on-error"] == true and
      ($action[0].uses | type == "string" and test("^oxsecurity/megalinter/flavors/go@[0-9a-f]{40}$")) and
      $action[0].env.MEGALINTER_CONFIG == "${{ github.workspace }}/.mega-linter.yml" and
      $action[0].env.DEFAULT_WORKSPACE == ("${{ steps.prepare-" + $case + ".outputs.workspace }}") and
      $action[0].env.REPORT_OUTPUT_FOLDER == ("/github/workspace/megalinter-bad-fixture-reports-" + $case) and
      $action[0].env.ENABLE_LINTERS == "JSON_JSONLINT" and
      $action[0].env.JSON_JSONLINT_CLI_LINT_MODE == "file" and
      $action[0].env.JSON_REPORTER == false and $action[0].env.TAP_REPORTER == true and
      $action[0].env.TAP_REPORTER_OUTPUT_DETAIL == "detailed" and $action[0].env.APPLY_FIXES == "none" and
      ($action[0].env | has("GITHUB_TOKEN") | not) and
      $assert[0].if == "${{ !cancelled() }}" and
      $assert[0].run == "bash .github/tests/megalinter-config-container.sh assert" and
      $assert[0].env.OUTCOME == ("${{ steps.ml-" + $case + ".outcome }}") and
      $assert[0].env.SCENARIO == $case and
      ($assert[0] | has("continue-on-error") | not))
  ' "$1" >/dev/null
}
native_admit "$scratch/native.json" || {
  echo 'TEST FAIL -- single-runner native scenarios, independent receipts or failure propagation are incomplete' >&2
  exit 1
}
count_native=0
for mutation in \
  'del(.steps[] | select(.id == "prepare-nested" or .id == "ml-nested" or .id == "assert-nested"))' \
  '(.steps[] | select(.id == "ml-root") | .env.MEGALINTER_CONFIG)=".mega-linter.yml"' \
  '(.steps[] | select(.id == "ml-finding") | .env.REPORT_OUTPUT_FOLDER)="/github/workspace/megalinter-bad-fixture-reports-root"' \
  '(.steps[] | select(.id == "ml-absent") | .env.JSON_REPORTER)=true' \
  '(.steps[] | select(.id == "ml-root") | .env.TAP_REPORTER)=false' \
  '(.steps[] | select(.id == "ml-nested") | .env.TAP_REPORTER_OUTPUT_DETAIL)="simple"' \
  '(.steps[] | select(.id == "ml-root") | .env.APPLY_FIXES)="all"' \
  '(.steps[] | select(.id == "assert-finding") | .if)="false"' \
  '(.steps[] | select(.id == "prepare-finding") | .if)="success()"' \
  '(.steps[] | select(.id == "ml-finding") | .if)="always()"' \
  '(.steps[] | select(.id == "assert-root") | ."continue-on-error")=true' \
  '(.steps[] | select(.id == "prepare-root") | ."continue-on-error")=true' \
  "(.steps[] | select(.id == \"assert-nested\") | .env.OUTCOME)=\"\${{ steps.ml-root.outcome }}\"" \
  '(.steps[] | select(.id == "prepare-absent") | .env.SCENARIO)="root"' \
  '.steps |= reverse' \
  '(.steps[] | select(.id == "ml-root") | .uses)="actions/checkout@0123456789abcdef0123456789abcdef01234567"' \
  '.steps += [.steps[] | select(.id == "ml-root") | {uses}] | (.steps[] | select(.id == "ml-root") | .uses)="actions/checkout@0123456789abcdef0123456789abcdef01234567"'; do
  jq "$mutation" "$scratch/native.json" >"$scratch/native-mutant.json"
  if cmp -s "$scratch/native.json" "$scratch/native-mutant.json" || native_admit "$scratch/native-mutant.json"; then
    echo "TEST FAIL -- native configuration proof mutation admitted: $mutation" >&2
    exit 1
  fi
  count_native=$((count_native + 1))
done
echo "TEST PASS -- repository-root container configuration and $count rejected binding substitutions"
echo "TEST PASS -- five native scenarios on one runner and $count_native rejected proof substitutions"
