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
reports="$scratch/megalinter-bad-fixture-reports/tap"
mkdir -p "$reports"
prefix='/github/workspace/.github/tests/megalinter-bad-fixture/config-probe'
report="$reports/mega-linter-JSON_JSONLINT.tap"
observe() {
  SCENARIO="$1" OUTCOME="$2" GITHUB_WORKSPACE="$scratch" \
    bash "$root/.github/tests/megalinter-config-container.sh" assert
}
healthy() { printf 'TAP version 13\n1..1\nok 1 - %s/config-probe-checked.json\n' "$prefix"; }
finding() {
  printf 'TAP version 13\n1..1\nnot ok 1 - %s/config-probe-checked.json\n  ---\n  message: Parse error on line 1\n  ...\n' "$prefix"
}
for scenario in root nested; do
  healthy >"$report"
  observe "$scenario" success
done
finding >"$report"
observe finding failure
printf 'TAP version 13\n1..2\nnot ok 1 - %s/config-probe-bad.json\n  ---\n  message: Parse error on line 1\n  ...\nok 2 - %s/config-probe-checked.json\n' "$prefix" "$prefix" >"$report"
observe absent failure
for mutation in header plan empty duplicate wrong-file wrong-path index unknown-line extra-result missing-result; do
  healthy >"$scratch/healthy.tap"
  case "$mutation" in
    header) sed 's/TAP version 13/TAP version 12/' "$scratch/healthy.tap" >"$report" ;;
    plan) sed 's/1\.\.1/1..2/' "$scratch/healthy.tap" >"$report" ;;
    empty) : >"$report" ;;
    duplicate) healthy >"$report"; printf 'ok 1 - %s/config-probe-checked.json\n' "$prefix" >>"$report" ;;
    wrong-file) sed 's/config-probe-checked.json/unrelated.json/' "$scratch/healthy.tap" >"$report" ;;
    wrong-path) sed 's@.github/tests/megalinter-bad-fixture/config-probe/@other/@' "$scratch/healthy.tap" >"$report" ;;
    index) sed 's/ok 1/ok 2/' "$scratch/healthy.tap" >"$report" ;;
    unknown-line) healthy >"$report"; printf 'unexpected receipt\n' >>"$report" ;;
    extra-result) healthy >"$report"; printf 'ok 2 - %s/config-probe-bad.json\n' "$prefix" >>"$report" ;;
    missing-result) printf 'TAP version 13\n1..1\n' >"$report" ;;
  esac
  if observe nested success >"$scratch/error" 2>&1; then
    echo "TEST FAIL -- incomplete or unrelated native receipt admitted: $mutation" >&2
    exit 1
  fi
done
for mutation in healthy operational absent-message wrong-file null-result wrong-outcome truncated-diagnostic; do
  finding >"$scratch/finding.tap"
  case "$mutation" in
    healthy) healthy >"$report" ;;
    operational) sed 's/Parse error on line 1/command not found/' "$scratch/finding.tap" >"$report" ;;
    absent-message) grep -v '  message:' "$scratch/finding.tap" >"$report" ;;
    wrong-file) sed 's/config-probe-checked.json/unrelated.json/' "$scratch/finding.tap" >"$report" ;;
    null-result) sed 's/not ok 1/unknown 1/' "$scratch/finding.tap" >"$report" ;;
    wrong-outcome) cp "$scratch/finding.tap" "$report" ;;
    truncated-diagnostic) sed '$d' "$scratch/finding.tap" >"$report" ;;
  esac
  outcome=failure
  [[ "$mutation" != wrong-outcome ]] || outcome=success
  if observe finding "$outcome" >"$scratch/error" 2>&1; then
    echo "TEST FAIL -- operational/contradictory failure counted as lint RED: $mutation" >&2
    exit 1
  fi
done
healthy >"$report"
if observe nested failure >"$scratch/error" 2>&1; then
  echo 'TEST FAIL -- failure outcome accepted for a healthy receipt' >&2
  exit 1
fi
rm "$report"
if observe absent failure >"$scratch/error" 2>&1; then
  echo 'TEST FAIL -- action failure without a checker receipt admitted' >&2
  exit 1
fi
echo 'TEST PASS -- four native TAP observer paths and 19 rejected receipt/outcome substitutions'
echo 'TEST PASS -- five actual native fixture preparations preserve scenario paths and bytes'
