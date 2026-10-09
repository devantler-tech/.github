#!/usr/bin/env bash
# Execute the composite's real scan body, including failure-before-output paths.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
module="$root/actions/validate-retired-repo-links"
yq -o=json '.' "$module/action.yaml" >"$scratch/action.json"
jq -er '.runs.steps[] | select(.id == "validate") | .run' "$scratch/action.json" >"$scratch/run.sh"

scan() {
  local config=$1 expected=$2 status=0
  : >"$scratch/outputs"
  env GOWORK=off GOFLAGS='' GOTOOLCHAIN=local \
    ACTION_PATH="$module" CONFIG_FILE="$config" \
    WORKING_DIRECTORY=.github/fixtures/retired-repo-links \
    GITHUB_WORKSPACE="$root" RUNNER_TEMP="$scratch" GITHUB_OUTPUT="$scratch/outputs" \
    bash "$scratch/run.sh" >"$scratch/scan.log" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]]; then
    cat "$scratch/scan.log" >&2
    echo "TEST FAIL -- scan returned $status, expected $expected" >&2
    exit 1
  fi
}

scan .github/retired-repo-links.json 0
if ! grep -Fxq "source-directory=$module" "$scratch/outputs"; then
  echo 'TEST FAIL -- successful scan did not expose its exact source directory' >&2
  exit 1
fi
grep -Fxq 'validated=true' "$scratch/outputs"
jq -e '.outputs["source-directory"].value == "${{ steps.validate.outputs.source-directory }}"' "$scratch/action.json" >/dev/null
source_directory=$(sed -n 's/^source-directory=//p' "$scratch/outputs")
env GOWORK=off GOFLAGS='' GOTOOLCHAIN=local \
  go -C "$source_directory" build -mod=readonly -trimpath -o "$scratch/consumer-validator" .
"$scratch/consumer-validator" --root "$root/.github/fixtures/retired-repo-links" >/dev/null

scan invalid.json 1
test ! -s "$scratch/outputs"
grep -Fq 'docs/history.md:3: link targets retired repository example/retired' "$scratch/scan.log"
scan missing.json 2
test ! -s "$scratch/outputs"
grep -q '^Invalid configuration:' "$scratch/scan.log"
echo 'TEST PASS -- exact usable source after success; no outputs after retired-link or missing-config failure'
