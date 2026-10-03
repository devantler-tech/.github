#!/usr/bin/env bash
# Suppress private coverage diagnostics while preserving the complete auditor result.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
audit_finished=0
# An incomplete coordinator cannot authorize a recovery report.
audit_cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$work" || status=2
  if [[ "$audit_finished" != 1 ]]; then
    echo 'governance-audits: UNKNOWN; audit coordinator did not finish' >&2
    status=2
  fi
  exit "$status"
}
trap 'audit_cleanup' EXIT
status=0
bash "$root/scripts/check-repository-admin-teams.sh" || status=$?
if [[ "$status" != 0 ]]; then
  audit_finished=1
  [[ "$status" == 1 ]] && exit 1
  exit 2
fi
status=0
bash "$root/scripts/check-repository-coverage.sh" >"$work/coverage.log" 2>&1 || status=$?
audit_finished=1
case "$status" in
0) echo 'governance-audits: PASS; both complete audits passed' ;;
1)
  echo 'governance-audits: DRIFT; repository coverage needs attention' >&2
  exit 1
  ;;
*)
  echo 'governance-audits: UNKNOWN; repository coverage did not complete' >&2
  exit 2
  ;;
esac
