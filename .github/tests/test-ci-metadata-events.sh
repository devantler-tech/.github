#!/usr/bin/env bash
# Metadata edits re-run the trusted guards without cancelling catalogue CI (#250).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ci="$repo_root/.github/workflows/ci.yaml"
guards="$repo_root/.github/workflows/deploy-guards.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

check_events() {
  local ci_file="$1" guard_file="$2" ci_events guard_events event
  ci_events="$(yq -o=json '.on.pull_request.types' "$ci_file")" || return 1
  guard_events="$(yq -o=json '.on.pull_request.types' "$guard_file")" || return 1
  if ! jq -e 'type == "array" and length > 0 and all(.[]; type == "string") and (index("edited") == null)' <<<"$ci_events" >/dev/null; then
    echo 'metadata-events: catalogue CI must not restart on edited' >&2
    return 1
  fi
  for event in opened synchronize reopened ready_for_review; do
    jq -e --arg event "$event" 'index($event) != null' <<<"$ci_events" >/dev/null || {
      echo "metadata-events: catalogue CI lost the $event event" >&2
      return 1
    }
  done
  jq -e 'type == "array" and index("edited") != null' <<<"$guard_events" >/dev/null || {
    echo 'metadata-events: trusted guards must judge edited pull requests' >&2
    return 1
  }
  yq -o=json '.on' "$ci_file" | jq -e 'has("push") and has("merge_group")' >/dev/null || return 1
}

check_events "$ci" "$guards"
echo 'ok: edits reach trusted guards; code changes, main pushes and merge groups retain CI'

# The declared required workflow and trusted-source boundary must remain intact.
bash "$repo_root/tests/deploy-guards-ruleset.sh"

yq '.on.pull_request.types += ["edited"]' "$ci" >"$work/ci-edited.yaml"
if check_events "$work/ci-edited.yaml" "$guards" >"$work/mutation.log" 2>&1; then
  echo 'FAIL: restored edited trigger was accepted' >&2
  exit 1
fi
grep -qF 'catalogue CI must not restart on edited' "$work/mutation.log"

yq '.on.pull_request.types -= ["edited"]' "$guards" >"$work/guards-no-edited.yaml"
if check_events "$ci" "$work/guards-no-edited.yaml" >"$work/mutation.log" 2>&1; then
  echo 'FAIL: guards without edited were accepted' >&2
  exit 1
fi
grep -qF 'trusted guards must judge edited' "$work/mutation.log"
echo 'ok: mutations restoring catalogue restarts or dropping metadata enforcement are rejected'
