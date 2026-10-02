#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
guard="$root/.github/tests/test-sync-cluster-policies-credentials.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
bash "$guard" >"$work/output" 2>&1 || fail "healthy interface failed: $(cat "$work/output")"
reject() {
  local label="$1" file="$2" expression="$3" diagnostic="$4"
  cp "$root/.github/workflows/sync-cluster-policies.yaml" "$work/workflow.yaml"
  cp "$root/.github/workflows/ci.yaml" "$work/ci.yaml"
  yq -i "$expression" "$work/$file.yaml"
  if bash "$guard" "$work/workflow.yaml" "$work/ci.yaml" >"$work/output" 2>&1; then
    fail "$label was accepted"
  fi
  grep -q "$diagnostic" "$work/output" || fail "$label failed for another reason: $(cat "$work/output")"
  echo "PASS: $label is rejected"
}
reject 'restored required secret' workflow '.on.workflow_call.secrets.APP_PRIVATE_KEY.required = true' 'at workflow admission'
reject 'forwarded App key' ci '.jobs.test-sync-cluster-policies.secrets.APP_PRIVATE_KEY = "fixture"' 'forwards secrets'
reject 'live sync in CI' ci '.jobs.test-sync-cluster-policies.with.dry-run = false' 'remain a dry-run'
reject 'production reached by dry-run' workflow '.jobs.sync-policies.if = "true"' 'reach the production job'
reject 'removed production credential preflight' workflow 'del(.jobs.sync-policies.steps[] | select(.id == "require-app-key"))' 'preflight is missing'
reject 'missing production key accepted' workflow '(.jobs.sync-policies.steps[] | select(.id == "require-app-key") | .run) = "true"' 'accepted an empty App key'
reject 'secret replaced with empty input' workflow '(.jobs.sync-policies.steps[] | select(.id == "require-app-key") | .env.APP_PRIVATE_KEY) = ""' 'does not read the supplied secret'
reject 'new unguarded sync job' workflow '.jobs.extra = {"runs-on": "ubuntu-latest", "steps": [{"run": "true"}]}' 'additional jobs'
reject 'restored caller write permission' ci '.jobs.test-sync-cluster-policies.permissions.contents = "write"' 'requests repository permissions'
