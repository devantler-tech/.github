#!/usr/bin/env bash
# Exercise the real harness pull boundary without a registry or container runtime.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == pull && $# == 2 ]] || exit 72
printf '%s\n' "$2" >>"${PULL_CALLS:?}"
attempts="$(wc -l <"$PULL_CALLS")"
(( PULL_FAILURES >= 0 && attempts > PULL_FAILURES )) || exit 73
DOCKER
cat >"$work/bin/go" <<'GO'
#!/usr/bin/env bash
printf '%s\n' 'post-pull build reached' >"${PULL_GATE:?}"
exit 91
GO
chmod +x "$work/bin/docker" "$work/bin/go"
for failures in 2 -1; do
  calls="$work/calls-$failures" gate="$work/gate-$failures"
  : >"$calls"
  status=0
  PATH="$work/bin:$PATH" PULL_CALLS="$calls" PULL_GATE="$gate" PULL_FAILURES="$failures" \
    RETRY_MAX_ATTEMPTS=3 RETRY_BASE_DELAY=0 \
    bash "$root/.github/tests/test-todo-scanner.sh" >"$work/output" 2>&1 || status=$?
  attempts="$(wc -l <"$calls")"
  if (( attempts != 3 )) || { (( failures == 2 )) && { [[ "$status" != 91 ]] || [[ ! -f "$gate" ]]; }; } ||
    { (( failures < 0 )) && { [[ "$status" != 73 ]] || [[ -f "$gate" ]]; }; }; then
    echo "FAIL: registry retry boundary (failures=$failures, attempts=$attempts, status=$status)" >&2
    cat "$work/output"
    exit 1
  fi
done
echo 'PASS: scanner pull recovers transient failure and propagates exhaustion'
