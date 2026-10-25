#!/usr/bin/env bash
# #751: future Renovate onboarding inherits the standing dashboard opt-out.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
finished=0

# Preserve failures on every supported Bash, including an interrupted observation.
cleanup() {
  local rc=$?
  rm -rf "$work"
  if [ "$finished" != 1 ] && [ "$rc" -eq 0 ]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT

# Validate the actual public onboarding preset, rather than the absence of a dashboard issue.
check_preset() {
  local input=$1
  if [ ! -f "$input" ] || [ -L "$input" ]; then
    echo 'organization onboarding preset is missing or linked'
    return 1
  fi
  jq -es 'length==1 and (.[0] | type=="object" and
    .extends==["config:recommended"] and .dependencyDashboard==false)' "$input" >/dev/null || {
    echo 'preset must retain recommended onboarding and disable Dependency Dashboard'
    return 1
  }
}

check_preset "$repo_root/renovate-config.json"
jq -S . "$repo_root/renovate-config.json" >"$work/preset.json"
check_preset "$work/preset.json"

# Each counterexample must fail the policy assertion, not an unrelated setup command.
expect_refusal() {
  if check_preset "$work/mutant.json" >"$work/result" 2>&1; then
    echo 'onboarding policy mutation unexpectedly passed' >&2
    exit 1
  fi
  grep -Fxq 'preset must retain recommended onboarding and disable Dependency Dashboard' "$work/result"
}
for mutation in '.dependencyDashboard=true' 'del(.dependencyDashboard)' \
  '.dependencyDashboard="false"' '.extends=[]' '.extends=[":dependencyDashboard"]'; do
  jq "$mutation" "$work/preset.json" >"$work/mutant.json"
  expect_refusal
done
printf '{"dependencyDashboard":' >"$work/mutant.json"
expect_refusal
: >"$work/mutant.json"
expect_refusal
cat "$work/preset.json" "$work/preset.json" >"$work/mutant.json"
expect_refusal

finished=1
printf 'Renovate onboarding preset: PASS (native policy and eight refusal controls)\n'
