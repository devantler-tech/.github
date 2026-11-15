#!/usr/bin/env bash
# All paths are relative to the checkout, except the absolute scanner executable.
# JSON mode returns zero even for findings. Judge findings separately, and never
# let an operational failure or malformed stream become a successful verdict.
set -euo pipefail
scanner="$1" module="$2" allow_file="${3-}" output_file="${4-}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
monitor_pid=''
stop_monitor() {
  if [[ -n "$monitor_pid" ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=''
  fi
}
cleanup() {
  stop_monitor
  rm -rf "$work"
}
trap cleanup EXIT

scan_command=("$scanner")
if [[ "$(uname -s)" == Linux ]]; then
  # Stream aggregate host pressure while the scanner is alive: a lost runner
  # cannot upload an after-the-fact report. Never print processes or environment.
  echo 'govulncheck-resource sample interval_seconds=30 max_samples=49' >&2
  if command -v vmstat >/dev/null 2>&1; then
    vmstat --wide --one-header 30 49 >&2 &
    monitor_pid=$!
  else
    echo '::warning::vmstat is unavailable; live resource samples cannot be collected.' >&2
  fi
  if [[ -x /usr/bin/time ]]; then
    scan_command=(/usr/bin/time --quiet -f 'govulncheck-resource usage elapsed_seconds=%e max_rss_kib=%M user_seconds=%U system_seconds=%S' "$scanner")
  else
    echo '::warning::GNU time is unavailable; scanner peak memory cannot be collected.' >&2
  fi
fi

rc=0
(cd "$module" && "${scan_command[@]}" -format=json -scan=symbol ./...) >"$work/scan.json" || rc=$?
stop_monitor
if [[ "$(uname -s)" == Linux ]]; then
  printf 'govulncheck-resource scanner_exit=%s\n' "$rc" >&2
fi
if [[ -n "$output_file" ]]; then
  cp "$work/scan.json" "$output_file"
fi
if ((rc != 0)); then
  echo "::error::govulncheck failed to run (exit $rc): operational error, not a scan result."
  exit "$rc"
fi
if ! jq -ers -f "$script_dir/reachable.jq" "$work/scan.json" >"$work/called.json"; then
  echo '::error::govulncheck returned invalid scan output; no successful verdict is possible.'
  exit 2
fi

# Keep the existing allow-file format: whitespace-separated IDs, # comments and
# blank lines. Only complete IDs match; a prefix or malformed entry accepts none.
: >"$work/allow.txt"
if [[ -n "$allow_file" ]]; then
  if [[ -f "$allow_file" ]]; then
    sed 's/#.*//' "$allow_file" | tr -s ' \t\r' '\n' >"$work/allow.txt"
  else
    echo '::warning::The requested allow-file was not found; scanning in strict mode.'
  fi
fi

blocking=0
while IFS= read -r id; do
  if grep -qxF "$id" "$work/allow.txt"; then
    echo "$id - ALLOWLISTED"
  else
    echo "$id - BLOCKING (https://pkg.go.dev/vuln/$id)"
    blocking=1
  fi
done < <(jq -r '.[]' "$work/called.json")
if ((blocking)); then
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo 'verdict=blocking' >>"$GITHUB_OUTPUT"; fi
  echo '::error::Reachable vulnerabilities are not accepted. Upgrade the affected dependency, remove the call, or document an explicit risk acceptance.'
  exit 1
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo 'verdict=clean' >>"$GITHUB_OUTPUT"; fi
echo 'No blocking vulnerabilities (accepted advisories, if any, are listed above).'
