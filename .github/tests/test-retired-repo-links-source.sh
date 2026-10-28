#!/usr/bin/env bash
# Execute the composite's real scan body, including failure-before-output paths.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
module="$root/actions/validate-retired-repo-links"
yq -o=json '.' "$module/action.yaml" >"$scratch/action.json"
jq -er '.runs.steps[] | select(.id == "validate") | .run' "$scratch/action.json" >"$scratch/run.sh"

# Runs the real composite scan, checks its expected exit status, and retains outputs for assertions.
scan() {
  local config=$1 expected=$2 source=${3:-$module} status=0
  : >"$scratch/outputs"
  env GOWORK=off GOFLAGS='' GOTOOLCHAIN=local \
    ACTION_PATH="$source" CONFIG_FILE="$config" \
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

# Native source lives in the runner action cache, separately from the checkout.
# Exercise the actual consumer assertions with the real scan output, so a path
# equality requirement cannot masquerade as a source-identity check.
cp -R "$module" "$scratch/native-source"
native_source="$scratch/native-source"
mkdir -p "$scratch/windows-checkout/actions"
cp -R "$module" "$scratch/windows-checkout/actions/validate-retired-repo-links"
awk '{printf "%s\r\n",$0}' "$module/main.go" >"$scratch/windows-checkout/actions/validate-retired-repo-links/main.go"
scan .github/retired-repo-links.json 0 "$native_source"
grep -Fxq "source-directory=$native_source" "$scratch/outputs"
for expression in \
  '.jobs.test-validate-retired-repo-links.steps[] | select(.name == "Assert action results") | .run' \
  '.jobs.test-validate-retired-repo-links-disabled.steps[] | select(.env.OMITTED_SOURCE != null) | .run'; do
  yq -er "$expression" "$root/.github/workflows/ci.yaml" >"$scratch/consumer-assertion.sh"
  assert_source() {
    (cd "${1:-$root}"; env VALIDATED=true VIOLATION=failure INVALID_VALIDATED='' INVALID_SOURCE='' \
      MISSING_CONFIG=failure MISSING_VALIDATED='' MISSING_SOURCE='' SOURCE="$native_source" \
      OMITTED=true OMITTED_SOURCE="$native_source" OMITTED_VIOLATION=failure OMITTED_VIOLATION_VALIDATED='' \
      DISABLED='' DISABLED_SOURCE='' INVALID=failure bash -euo pipefail "$scratch/consumer-assertion.sh")
  }
  assert_source || { echo 'TEST FAIL -- hosted assertion rejects identical native action source outside the checkout' >&2; exit 1; }
  assert_source "$scratch/windows-checkout" || { echo 'TEST FAIL -- native source comparison rejects Windows checkout line endings' >&2; exit 1; }
  printf '\n// deliberately different source\n' >>"$native_source/main.go"
  if assert_source >"$scratch/mismatch.log" 2>&1; then
    echo 'TEST FAIL -- hosted assertion accepted different implementation bytes' >&2
    exit 1
  fi
  cp "$module/main.go" "$native_source/main.go"
done
echo 'TEST PASS -- native source works outside the workspace; changed implementation is rejected'
