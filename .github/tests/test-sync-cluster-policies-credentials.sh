#!/usr/bin/env bash
# Fork CI must validate the same policy-sync interface without a production App key.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/sync-cluster-policies.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(yq '.on.workflow_call.secrets.APP_PRIVATE_KEY.required' "$workflow")" == false ]] ||
  fail 'policy-sync dry-runs still require an App key at workflow admission'
[[ "$(yq '.jobs.test-sync-cluster-policies.with.dry-run' "$ci")" == true ]] ||
  fail 'catalogue policy-sync test must remain a dry-run'
[[ "$(yq '.jobs.test-sync-cluster-policies.secrets // {} | length' "$ci")" == 0 ]] ||
  fail 'catalogue policy-sync test forwards secrets'
[[ "$(yq '.jobs.sync-policies.if' "$workflow")" == "\${{ !inputs.dry-run }}" ]] ||
  fail 'dry-runs may reach the production job'
[[ "$(yq '.jobs | keys | join(",")' "$workflow")" == sync-policies ]] ||
  fail 'policy-sync has additional jobs without validated dry-run admission'
[[ "$(yq '.jobs.test-sync-cluster-policies.permissions | tag' "$ci")" == '!!map' &&
  "$(yq '.jobs.test-sync-cluster-policies.permissions | length' "$ci")" == 0 ]] ||
  fail 'catalogue policy-sync test requests repository permissions'

# Execute the actual credential preflight: optional interface does not mean optional
# production authentication. Nothing after this step may mint a token on missing input.
yq -r '.jobs.sync-policies.steps[] | select(.id == "require-app-key") | .run' "$workflow" >"$work/check.sh"
[[ -s "$work/check.sh" && "$(cat "$work/check.sh")" != null ]] || fail 'production credential preflight is missing'
[[ "$(yq '.jobs.sync-policies.steps[] | select(.id == "require-app-key") | .env.APP_PRIVATE_KEY' "$workflow")" == "\${{ secrets.APP_PRIVATE_KEY }}" ]] ||
  fail 'production credential preflight does not read the supplied secret'
if APP_PRIVATE_KEY='' bash -e "$work/check.sh" >"$work/missing.log" 2>&1; then
  fail 'production sync accepted an empty App key'
fi
grep -q '::error::.*APP_PRIVATE_KEY' "$work/missing.log" || fail 'missing key produced no actionable error'
APP_PRIVATE_KEY='fixture-not-a-secret' bash -e "$work/check.sh" >"$work/present.log" 2>&1 ||
  fail 'production sync rejected a supplied key'
[[ ! -s "$work/present.log" ]] || fail 'credential preflight printed its input'
[[ "$(yq '[.jobs.sync-policies.steps[].id] | .[1]' "$workflow")" == require-app-key ]] ||
  fail 'credential preflight must follow hardening and precede token creation'
echo 'PASS: dry-runs admit without secrets; production requires its key before token creation'
