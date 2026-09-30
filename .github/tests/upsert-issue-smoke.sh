#!/usr/bin/env bash
# Prepare and verify the offline CLI used by the hosted composite-action smoke test.
set -euo pipefail
work="${RUNNER_TEMP:?}/upsert-issue-smoke"

case "${1:-}" in
  prepare)
    mkdir -p "$work/bin"
    : >"$work/calls"
    cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
work="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${GH_TOKEN:-}" == offline-fixture ]] || { echo 'fixture token missing' >&2; exit 1; }
jq -cn --args '$ARGS.positional' -- "$@" >>"$work/calls"
case "$1 $2" in
  "issue list") printf '[]\n' ;;
  "issue create") printf 'https://github.com/offline/fixture/issues/99\n' ;;
  *) echo "unexpected offline CLI command" >&2; exit 1 ;;
esac
STUB
    chmod +x "$work/bin/gh"
    printf '%s\n' "$work/bin" >>"${GITHUB_PATH:?}"
    ;;
  verify)
    [[ "${ISSUE_NUMBER:-}" == 99 && "${ISSUE_URL:-}" == https://github.com/offline/fixture/issues/99 ]] || {
      echo "FAIL: hosted action outputs did not reach the caller" >&2
      exit 1
    }
    jq -se '
      def flag($name): .[index($name) + 1];
      length == 3 and
      .[0][0:2] == ["issue","list"] and (.[0] | flag("--state")) == "open" and
      .[1][0:2] == ["issue","list"] and (.[1] | flag("--state")) == "closed" and
      .[2][0:2] == ["issue","create"] and
      all(.[]; flag("--repo") == "offline/fixture") and
      (.[2] | flag("--title")) == "Offline smoke fixture" and
      (.[2] | flag("--body")) == "Offline smoke body" and
      (.[2] | flag("--label")) == "bug"
    ' "$work/calls" >/dev/null
    echo "PASS: hosted upsert-issue uses the offline CLI and returns exact outputs"
    ;;
  *) echo "usage: upsert-issue-smoke.sh <prepare|verify>" >&2; exit 2 ;;
esac
