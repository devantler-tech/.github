#!/usr/bin/env bash
# The native matrix proves loader/checker behavior; this guard pins the actual
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
    .permissions == {contents:"read"} and .strategy["fail-fast"] == false and
    (.strategy.matrix.scenario | sort) ==
      ["absent","finding","malformed","nested","root"] and
    [.steps[] | select(.id == "config-probe")] as $prepare |
    [.steps[] | select(.id == "ml")] as $action |
    [.steps[] | select(.run == "bash .github/tests/megalinter-config-container.sh assert")] as $assert |
    ($prepare | length) == 1 and ($action | length) == 1 and ($assert | length) == 1 and
    $prepare[0].run == "bash .github/tests/megalinter-config-container.sh prepare" and
    $prepare[0].env.SCENARIO == "${{ matrix.scenario }}" and
    $action[0]["continue-on-error"] == true and
    $action[0].env.MEGALINTER_CONFIG == "${{ github.workspace }}/.mega-linter.yml" and
    $action[0].env.DEFAULT_WORKSPACE == "${{ steps.config-probe.outputs.workspace }}" and
    $action[0].env.REPORT_OUTPUT_FOLDER == "/github/workspace/megalinter-bad-fixture-reports" and
    $action[0].env.ENABLE_LINTERS == "JSON_JSONLINT" and
    $action[0].env.JSON_JSONLINT_CLI_LINT_MODE == "file" and
    $action[0].env.JSON_REPORTER == true and $action[0].env.APPLY_FIXES == "none" and
    ($action[0].env | has("GITHUB_TOKEN") | not) and
    $assert[0].env.OUTCOME == "${{ steps.ml.outcome }}" and
    $assert[0].env.SCENARIO == "${{ matrix.scenario }}" and
    all([$prepare[0],$action[0],$assert[0]][]; has("if") | not) and
    ($assert[0] | has("continue-on-error") | not)
  ' "$1" >/dev/null
}
native_admit "$scratch/native.json" || {
  echo 'TEST FAIL -- required native configuration matrix or checker receipts are incomplete' >&2
  exit 1
}
for mutation in \
  '.strategy.matrix.scenario |= map(select(. != "nested"))' \
  '(.steps[] | select(.id == "ml") | .env.MEGALINTER_CONFIG)=".mega-linter.yml"' \
  '(.steps[] | select(.id == "ml") | .env.REPORT_OUTPUT_FOLDER)="/home/unrelated/reports"' \
  '(.steps[] | select(.id == "ml") | .env.JSON_REPORTER)=false' \
  '(.steps[] | select(.id == "ml") | .env.APPLY_FIXES)="all"' \
  '(.steps[] | select(.run == "bash .github/tests/megalinter-config-container.sh assert") | .if)="false"'; do
  jq "$mutation" "$scratch/native.json" >"$scratch/native-mutant.json"
  if cmp -s "$scratch/native.json" "$scratch/native-mutant.json" || native_admit "$scratch/native-mutant.json"; then
    echo "TEST FAIL -- native configuration proof mutation admitted: $mutation" >&2
    exit 1
  fi
done
echo "TEST PASS -- repository-root container configuration and $count rejected binding substitutions"
echo 'TEST PASS -- five native scenarios and six rejected proof substitutions'
