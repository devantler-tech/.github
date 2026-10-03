#!/usr/bin/env bash
# Compare organization settings without changing GitHub state.
# 0 = complete match; 1 = measured drift; 2 = invalid or incomplete evidence.
set -Eeuo pipefail
finished=false
work=""
on_exit() {
  local status="${1:-$?}"
  trap - EXIT
  if [[ -n "$work" ]]; then rm -rf "$work" || status=2; fi
  if [[ "$finished" != true ]]; then
    echo 'organization-settings: UNKNOWN; audit did not finish' >&2
    status=2
  fi
  exit "$status"
}
trap 'on_exit' EXIT
finish() {
  finished=true
  on_exit "$1"
}
unknown() {
  echo "organization-settings: UNKNOWN; $1" >&2
  finish 2
}
root="$(cd "$(dirname "$0")/.." && pwd)"
policy="$root/organization-settings/expected.json"
if (($# > 0)); then
  [[ $# == 2 && "$1" == --policy ]] || unknown 'usage: check-organization-settings.sh [--policy file]'
  policy="$2"
fi
[[ -f "$policy" ]] || unknown 'audit policy is not readable'
work="$(mktemp -d)"
# Treat only one complete JSON document as a policy or observation.
typed_settings='
  (.web_commit_signoff_required | type) == "boolean" and
  (.members_can_create_repositories | type) == "boolean" and
  (.two_factor_requirement_enabled | type) == "boolean" and
  (.default_repository_permission | IN("none", "read", "write", "admin"))'
if ! jq -es '
  length == 1 and (.[0] |
    type == "object" and keys == ["organization","settings"] and
    .organization == "devantler-tech" and
    (.settings | type == "object" and
      keys == ["default_repository_permission","members_can_create_repositories","two_factor_requirement_enabled","web_commit_signoff_required"] and
      '"$typed_settings"'))' "$policy" >/dev/null 2>&1; then
  unknown 'audit policy is malformed or unsupported'
fi
organization="$(jq -r .organization "$policy")"
# Check the producer status before parsing: plausible partial stdout is not a read.
if ! gh api "orgs/$organization" >"$work/live.json" 2>"$work/error"; then
  unknown 'organization read failed'
fi
if ! jq -es '
  length == 1 and (.[0] | type == "object" and
    .login == "devantler-tech" and
    (.id | type == "number" and floor == . and . > 0) and
    '"$typed_settings"')' "$work/live.json" >/dev/null 2>&1; then
  unknown 'organization read lacks a complete typed observation'
fi
differences="$(jq -r --slurpfile policy "$policy" '
  . as $live | [$policy[0].settings | to_entries[] |
    select($live[.key] != .value)] | length' "$work/live.json")"
if [[ "$differences" != 0 ]]; then
  echo "organization-settings: DRIFT; $differences declared setting differs"
  finish 1
fi
echo 'organization-settings: PASS; all 4 declared settings match'
finish 0
