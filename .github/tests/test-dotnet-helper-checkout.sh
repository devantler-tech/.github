#!/usr/bin/env bash
# Exercise native action-cache isolation, then run the action's real test command
# from a consumer root. An in-workspace helper must still reproduce #258.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$root/.github/actions/test-dotnet-fixture/action.yaml}"
mode="${2:-offline}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$mode" == offline || "$mode" == hosted ]] || fail 'unknown test mode'

yq -o=json . "$workflow" | jq -e '
  [.runs.steps[] | select(.uses != null) | .uses] == ["$/actions/run-dotnet-tests"]
' >/dev/null || fail 'native same-commit action reference is missing'
yq -er '.runs.steps[] | select(.name == "🧪 Test") | .run' "$root/actions/run-dotnet-tests/action.yaml" >"$work/test.sh"
yq -er '.runs.steps[] | select(.name == "🔀 Merge coverage into a single Cobertura report") | .run' \
  "$root/actions/run-dotnet-tests/action.yaml" >"$work/merge.sh"

mkdir -p "$work/bin"
cat >"$work/bin/dotnet" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'test --no-restore' ]] || { echo "unexpected coverage arguments: $*" >&2; exit 1; }
printf 'credential-free tests without coverage\n' > test-completed
SH
chmod +x "$work/bin/dotnet"

for fixture in run-dotnet-tests-mtp-no-coverage run-dotnet-tests; do
  consumer="$work/$fixture"
  mkdir -p "$consumer"
  cp -R "$root/.github/fixtures/$fixture/." "$consumer/"
  helper="$work/native-action-cache/$fixture"
  mkdir -p "$(dirname "$helper")"
  git clone --quiet --no-checkout --shared "$root" "$helper"
  git -C "$helper" checkout --quiet --detach HEAD
  [[ -f "$helper/actions/run-dotnet-tests/action.yaml" ]] || fail 'needed action was omitted'
  # Full source deliberately includes both kinds of scan input. The passing
  # consumer proves placement, not sparse omission, prevents contamination.
  [[ -f "$helper/.github/fixtures/run-dotnet-tests/src/Example/Example.csproj" ]] || fail 'project contamination control is absent'
  [[ -f "$helper/.github/fixtures/upload-coverage/coverage.cobertura.xml" ]] || fail 'coverage contamination control is absent'

  if [[ "$fixture" == run-dotnet-tests-mtp-no-coverage ]]; then
    if [[ "$mode" == hosted ]]; then
      (cd "$consumer" && dotnet restore && bash -eo pipefail "$work/test.sh")
    else
      (cd "$consumer" && PATH="$work/bin:$PATH" bash -eo pipefail "$work/test.sh") ||
        fail 'helper fixture enabled unsupported coverage for the consumer'
      [[ -f "$consumer/test-completed" ]] || fail 'consumer tests did not execute'
    fi
    echo 'PASS: root consumer without the extension runs without coverage'
  elif [[ "$mode" == hosted ]]; then
    (cd "$consumer" && dotnet restore && bash -eo pipefail "$work/test.sh" && bash -eo pipefail "$work/merge.sh")
    report="$consumer/coverage-merged/Cobertura.xml"
    [[ -s "$report" ]] || fail 'consumer coverage was not merged'
    grep -q 'Example' "$report" || fail 'consumer coverage is missing'
    if grep -q 'sample.go' "$report"; then fail 'catalogue coverage polluted the consumer report'; fi
    echo 'PASS: real consumer coverage merges without catalogue coverage'
  fi

  echo "PASS: $fixture action-cache scan inputs remain outside the consumer"
done

# Reproduce the original root-consumer failure using the identical action
# command, even in hosted mode. This guards against a vacuous isolation pass.
polluted="$work/polluted-consumer"
mkdir -p "$polluted"
cp -R "$root/.github/fixtures/run-dotnet-tests-mtp-no-coverage/." "$polluted/"
git clone --quiet --shared "$root" "$polluted/.devantler-tech-actions"
if (cd "$polluted" && PATH="$work/bin:$PATH" bash -eo pipefail "$work/test.sh") >"$work/contamination.log" 2>&1; then
  fail 'in-workspace catalogue source did not reproduce unsupported coverage'
fi
grep -q 'unexpected coverage arguments:' "$work/contamination.log" || fail 'negative control failed for an unrelated reason'
echo 'PASS: in-workspace helper reproduces the root-consumer regression'
