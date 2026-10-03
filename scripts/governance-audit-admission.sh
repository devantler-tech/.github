#!/usr/bin/env bash
# Admit only the reviewed main workflow; scheduled rollout starts disabled.
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
policy="$(cd "$(dirname "$0")/.." && pwd)/.github/governance-audits.json"
if (($# > 0)); then
  [[ $# == 2 && "$1" == --policy ]] || unknown
  policy="$2"
fi
jq -es 'length == 1 and (.[0] | type == "object" and keys == ["scheduled"] and
  (.scheduled | type == "boolean"))' "$policy" >/dev/null 2>&1 || unknown
enabled=false
if [[ "$GITHUB_EVENT_NAME" == schedule ]]; then
  [[ "${REQUESTED:-}" == '' ]] || unknown
  enabled="$(jq -r .scheduled "$policy")"
else
  case "${REQUESTED:-}" in true) enabled=true ;; false | '') ;; *) unknown ;; esac
fi
printf 'enabled=%s\n' "$enabled" >>"$GITHUB_OUTPUT"
finished=true
