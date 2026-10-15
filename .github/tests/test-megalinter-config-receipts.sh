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
prefix=''
report="$reports/mega-linter-JSON_JSONLINT.tap"
observe() {
  target="$scratch/megalinter-bad-fixture-reports-$1/tap"
  mkdir -p "$target"
  if [[ -f "$report" ]]; then
    cp "$report" "$target/mega-linter-JSON_JSONLINT.tap"
  else
    rm -f "$target/mega-linter-JSON_JSONLINT.tap"
  fi
  SCENARIO="$1" OUTCOME="$2" GITHUB_WORKSPACE="$scratch" \
    bash "$root/.github/tests/megalinter-config-container.sh" assert
}
healthy() { printf 'TAP version 13\n1..1\nok 1 - %sconfig-probe-checked.json\n' "$prefix"; }
finding() {
  printf 'TAP version 13\n1..1\nnot ok 1 - config-probe-checked.json\n  ---\n  message: File  config-probe-checked.json\\nParse error on line 2, column 26 \\n...liberatelyInvalid"  ,  "why"  "syntax e...\\n-----------------------^\\nNo value found for key "deliberatelyInvalid"\n  ...\n'
}
for scenario in root nested; do
  prefix=''
  [[ "$scenario" != root ]] || prefix='.github/tests/megalinter-bad-fixture/config-probe/'
  healthy >"$report"
  observe "$scenario" success
done
prefix=''
finding >"$report"
observe finding failure
printf 'TAP version 13\n1..2\nnot ok 1 - config-probe-bad.json\n  ---\n  message: File  config-probe-bad.json\\nParse error on line 2, column 26 \\n...liberatelyInvalid"  ,  "why"  "syntax e...\\n-----------------------^\\nNo value found for key "deliberatelyInvalid"\n  ...\nok 2 - config-probe-checked.json\n' >"$report"
observe absent failure
for mutation in header plan empty duplicate wrong-file wrong-path index unknown-line extra-result missing-result; do
  healthy >"$scratch/healthy.tap"
  case "$mutation" in
    header) sed 's/TAP version 13/TAP version 12/' "$scratch/healthy.tap" >"$report" ;;
    plan) sed 's/1\.\.1/1..2/' "$scratch/healthy.tap" >"$report" ;;
    empty) : >"$report" ;;
    duplicate) healthy >"$report"; printf 'ok 1 - config-probe-checked.json\n' >>"$report" ;;
    wrong-file) sed 's/config-probe-checked.json/unrelated.json/' "$scratch/healthy.tap" >"$report" ;;
    wrong-path) sed 's@config-probe-checked.json@other/config-probe-checked.json@' "$scratch/healthy.tap" >"$report" ;;
    index) sed 's/ok 1/ok 2/' "$scratch/healthy.tap" >"$report" ;;
    unknown-line) healthy >"$report"; printf 'unexpected receipt\n' >>"$report" ;;
    extra-result) healthy >"$report"; printf 'ok 2 - config-probe-bad.json\n' >>"$report" ;;
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
    operational) sed 's/Parse error on line 2/command not found/' "$scratch/finding.tap" >"$report" ;;
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

# A shared runner must restore fixture bytes after missing and invalid cases.
shared="$scratch/shared"
fixture="$shared/.github/tests/megalinter-bad-fixture"
mkdir -p "$fixture"
git -C "$shared" init --quiet
cp "$root/.mega-linter.yml" "$shared/.mega-linter.yml"
for file in bad.json config-probe.yml config-probe-checked.json config-probe-malformed.yml; do
  cp "$root/.github/tests/megalinter-bad-fixture/$file" "$fixture/$file"
done
for scenario in absent malformed finding root nested; do
  if ! SCENARIO="$scenario" GITHUB_WORKSPACE="$shared" GITHUB_OUTPUT="$shared/output" \
    bash "$root/.github/tests/megalinter-config-container.sh" prepare; then
    echo "TEST FAIL -- shared-runner preparation did not reset after the preceding case: $scenario" >&2
    exit 1
  fi
  case "$scenario" in
    absent) [[ ! -e "$shared/.mega-linter.yml" ]] ;;
    malformed) cmp "$fixture/config-probe-malformed.yml" "$shared/.mega-linter.yml" ;;
    *) cmp "$fixture/config-probe.yml" "$shared/.mega-linter.yml" ;;
  esac
  if [[ "$scenario" == finding ]]; then
    cmp "$fixture/bad.json" "$fixture/config-probe/config-probe-checked.json"
  else
    jq -e '.configurationProbe == true' "$fixture/config-probe/config-probe-checked.json" >/dev/null
  fi
done
echo 'TEST PASS -- sequential preparation restores absent, malformed and failed-file controls'

# A previous case cannot satisfy the next case's missing receipt.
rm -f "$scratch/megalinter-bad-fixture-reports-nested/tap/mega-linter-JSON_JSONLINT.tap"
prefix=''
healthy > "$scratch/megalinter-bad-fixture-reports/tap/mega-linter-JSON_JSONLINT.tap"
if SCENARIO=nested OUTCOME=success GITHUB_WORKSPACE="$scratch" \
  bash "$root/.github/tests/megalinter-config-container.sh" assert >"$scratch/error" 2>&1; then
  echo 'TEST FAIL -- stale shared receipt admitted for a different case' >&2
  exit 1
fi
mkdir -p "$shared/megalinter-bad-fixture-reports-root"
if SCENARIO=root GITHUB_WORKSPACE="$shared" GITHUB_OUTPUT="$shared/output" \
  bash "$root/.github/tests/megalinter-config-container.sh" prepare >"$scratch/error" 2>&1; then
  echo 'TEST FAIL -- preparation accepted an existing scenario report' >&2
  exit 1
fi
grep -F 'stale or linked scenario report path' "$scratch/error" >/dev/null
echo 'TEST PASS -- stale shared receipts and existing case reports are refused'
