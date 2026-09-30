#!/usr/bin/env bash
# Exercise the workflow's real checkout settings with Git, then run the action's
# test command from a consumer root. A full helper checkout must reproduce #258.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/run-dotnet-tests.yaml}"
mode="${2:-offline}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$mode" == offline || "$mode" == hosted ]] || fail 'unknown test mode'

checkout="$(yq -o=json '.jobs.test.steps[] | select(.with.path == ".devantler-tech-actions") | .with' "$workflow")"
[[ -n "$checkout" ]] || fail 'helper checkout is missing'
patterns="$(jq -r '."sparse-checkout" // empty' <<<"$checkout")"
cone="$(jq -r 'if has("sparse-checkout-cone-mode") then .["sparse-checkout-cone-mode"] else true end' <<<"$checkout")"
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
  helper="$consumer/.devantler-tech-actions"
  git clone --quiet --no-checkout --shared "$root" "$helper"
  if [[ -n "$patterns" ]]; then
    if [[ "$cone" == true ]]; then sparse_mode=--cone; else sparse_mode=--no-cone; fi
    printf '%s\n' "$patterns" | git -C "$helper" sparse-checkout set "$sparse_mode" --stdin
  fi
  git -C "$helper" checkout --quiet --detach HEAD
  [[ -f "$helper/actions/run-dotnet-tests/action.yaml" ]] || fail 'needed action was omitted'

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

  contamination="$(find "$helper" -type f \( -name '*.csproj' -o -name '*.props' -o -name '*.targets' -o -name '*.cobertura.xml' \) -print)"
  [[ -z "$contamination" ]] || fail 'helper checkout contains unrelated projects or coverage reports'
  echo "PASS: $fixture helper contains no scan inputs"
done
