#!/usr/bin/env bash
# Exercise the native proof's actual assertion helper with synthetic reporter
# bytes. These controls validate the observer, not the container/loader itself.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
for scenario in root nested absent malformed finding; do
  prepared="$scratch/$scenario"
  fixture="$prepared/.github/tests/megalinter-bad-fixture"
  mkdir -p "$fixture"
  git -C "$prepared" init --quiet
  cp "$root/.mega-linter.yml" "$prepared/.mega-linter.yml"
  for file in bad.json config-probe.yml config-probe-checked.json config-probe-malformed.yml; do
    cp "$root/.github/tests/megalinter-bad-fixture/$file" "$fixture/$file"
  done
  SCENARIO="$scenario" GITHUB_WORKSPACE="$prepared" GITHUB_OUTPUT="$prepared/output" \
    bash "$root/.github/tests/megalinter-config-container.sh" prepare
  expected_workspace=/github/workspace/.github/tests/megalinter-bad-fixture/config-probe
  case "$scenario" in root) expected_workspace=/github/workspace ;; esac
  grep -Fx "workspace=$expected_workspace" "$prepared/output" >/dev/null
  case "$scenario" in
    absent) [[ ! -e "$prepared/.mega-linter.yml" ]] ;;
    malformed) cmp "$fixture/config-probe-malformed.yml" "$prepared/.mega-linter.yml" ;;
    *) cmp "$fixture/config-probe.yml" "$prepared/.mega-linter.yml" ;;
  esac
  checked="$fixture/config-probe/config-probe-checked.json"
  if [[ "$scenario" == finding ]]; then
    cmp "$fixture/bad.json" "$checked"
  else
    jq -e '.configurationProbe == true' "$checked" >/dev/null
  fi
done
reports="$scratch/megalinter-bad-fixture-reports"
mkdir "$reports"
jq -n '{return_code:0,linters:[{name:"JSON_JSONLINT",is_active:true,
  return_code:0,files_number:1,files_lint_results:[{
    file:"/github/workspace/probe/config-probe-checked.json",status_code:0}]}]}' >"$scratch/healthy.json"
observe() {
  SCENARIO="$1" OUTCOME="$2" GITHUB_WORKSPACE="$scratch" \
    bash "$root/.github/tests/megalinter-config-container.sh" assert
}
for scenario in root nested; do
  cp "$scratch/healthy.json" "$reports/mega-linter-report.json"
  observe "$scenario" success
done
for mutation in \
  '.linters=[]' \
  '.linters[0].is_active=false' \
  '.linters[0].files_number=0' \
  '.linters[0].files_lint_results=[]' \
  '.linters[0].files_number=2' \
  '.linters[0].files_lint_results[0].file="/github/workspace/not-the-fixture.json"' \
  '.linters[0].files_lint_results[0].status_code=1' \
  '.return_code=1'; do
  jq "$mutation" "$scratch/healthy.json" >"$reports/mega-linter-report.json"
  if observe nested success >"$scratch/output" 2>&1; then
    echo "TEST FAIL -- incomplete or contradictory native receipt admitted: $mutation" >&2
    exit 1
  fi
done
for scenario in absent finding; do
  expected='config-probe-bad.json'
  [[ "$scenario" != finding ]] || expected='config-probe-checked.json'
  jq --arg file "/github/workspace/probe/$expected" '
    .return_code=1 | .linters[0].return_code=1 |
    .linters[0].files_lint_results[0] = {file:$file,status_code:1}' "$scratch/healthy.json" >"$scratch/finding.json"
  cp "$scratch/finding.json" "$reports/mega-linter-report.json"
  observe "$scenario" failure
  for mutation in \
    '.return_code=0' \
    '.linters[0].return_code=0' \
    '.linters[0].files_lint_results[0].status_code=0' \
    '.linters[0].files_lint_results[0].status_code=null' \
    '.linters[0].files_lint_results[0].file="/github/workspace/unrelated.json"'; do
    jq "$mutation" "$scratch/finding.json" >"$reports/mega-linter-report.json"
    if observe "$scenario" failure >"$scratch/output" 2>&1; then
      echo "TEST FAIL -- operational or unrelated failure counted as lint RED: $scenario/$mutation" >&2
      exit 1
    fi
  done
done
cp "$scratch/healthy.json" "$reports/mega-linter-report.json"
if observe nested failure >"$scratch/output" 2>&1; then
  echo 'TEST FAIL -- failure outcome accepted for a healthy receipt' >&2
  exit 1
fi
rm "$reports/mega-linter-report.json"
if observe absent failure >"$scratch/output" 2>&1; then
  echo 'TEST FAIL -- action failure without a checker receipt admitted' >&2
  exit 1
fi
echo 'TEST PASS -- four real assertion paths and 20 rejected receipt/outcome substitutions'
echo 'TEST PASS -- five actual native fixture preparations preserve scenario paths and bytes'
