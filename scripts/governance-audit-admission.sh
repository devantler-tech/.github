#!/usr/bin/env bash
# Admit routine audits only from the reviewed main workflow.
set -euo pipefail
finished=false
on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$finished" != true ]]; then
    echo 'governance-audits: UNKNOWN; admission did not finish' >&2
    status=2
  fi
  exit "$status"
}
trap 'on_exit' EXIT
unknown() {
  echo 'governance-audits: UNKNOWN; admission not established' >&2
  exit 2
}
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REPOSITORY:-}" == devantler-tech/.github &&
  "${GITHUB_REF:-}" == refs/heads/main &&
  "${GITHUB_WORKFLOW_REF:-}" == devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main &&
  "${GITHUB_WORKFLOW_SHA:-}" =~ ^[0-9a-f]{40}$ && -n "${GITHUB_OUTPUT:-}" ]] || unknown
case "${GITHUB_EVENT_NAME:-}" in schedule | workflow_dispatch) ;; *) unknown ;; esac
(($# == 0)) || unknown
printf 'enabled=true\n' >>"$GITHUB_OUTPUT"
finished=true
