#!/usr/bin/env bash
# Guards the runtime safety controls on validate-go-project.yaml's memory-hungry
# Go analysis jobs (actions#593, ksail#6957).
#
# TIMEOUT (govulncheck). A cold-cache scan of a large module runs ~14 min and a
# clean run crossed the old 15-min bound, so Actions cancelled a passing scan and
# failed the required check. A later KSail main run finished the scan after
# 17m44s, then setup-go's cache-save post-step hit the 20-minute job limit. The
# floor below keeps headroom over both phases while preserving a *finite* ceiling.
#
# GOMEMLIMIT CEILING (every job that sets one). GOMEMLIMIT is a SOFT limit: it
# tells the GC what to aim for, and it cannot bound genuinely-live heap or the
# non-Go memory around it (the runner agent, harden-runner, and the analysis
# tools' own `go list` / type-check subprocesses). Set too close to the host's
# RAM, the Go process is permitted to grow until total system RSS crosses the
# host ceiling and the HOST kills the runner mid-analysis — surfacing as an
# opaque "runner has received a shutdown signal" / exit 143 that no retry fixes.
# A presence-only check passes happily in exactly that state, which is how
# 12GiB-on-a-16GiB-runner shipped and OOM-killed ~1 vulnerability scan in 4
# (ksail#6957). Asserting the value leaves real headroom is what stops it
# regressing.
#
# The ceiling is applied to EVERY job declaring GOMEMLIMIT rather than to a list
# of job names, so a new memory-hungry job inherits the guard instead of needing
# to be remembered here.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-.github/workflows/validate-go-project.yaml}"
min_timeout="${2:-25}"
# Max GiB any job in this workflow may hand the Go runtime. `runs-on:
# ubuntu-latest` provides 16 GB to a public repository, so this leaves half the
# host for everything GOMEMLIMIT does not govern. A private repository's
# ubuntu-latest has 8 GB, which this ceiling already exceeds, so such a consumer
# needs a larger runner and a caller-side cap below it. Raise it only alongside a
# runner with more RAM.
max_gomemlimit_gib="${3:-8}"

# The ceiling is a caller-supplied parameter that reaches an arithmetic context in
# `((value_bytes > max_gomemlimit_gib * 1073741824))`, so it is validated the same way the
# GOMEMLIMIT values are. Without this, `8/0` raises a division-by-zero error that
# `set -e` does not abort on here: the comparison is skipped, `status` stays 0, and
# the script reports the ceiling satisfied without ever testing it. Bounding to nine
# digits also keeps `* 1073741824` clear of the 64-bit wrap that turns a huge ceiling into
# a tiny one, and `10#` reads a leading zero decimally rather than as octal.
if [[ ! "$max_gomemlimit_gib" =~ ^[0-9]{1,9}$ ]]; then
  echo "::error::GOMEMLIMIT ceiling must be 1-9 decimal digits so it cannot reach an arithmetic context unchecked; got '$max_gomemlimit_gib'"
  exit 1
fi
max_gomemlimit_gib=$((10#$max_gomemlimit_gib))
if ((max_gomemlimit_gib == 0)); then
  echo "::error::GOMEMLIMIT ceiling must be greater than zero; got '0'"
  exit 1
fi

status=0

timeout="$(yq -r '.jobs.govulncheck."timeout-minutes" // ""' "$workflow")"
if [[ -z "$timeout" || "$timeout" == "null" ]]; then
  echo "::error file=$workflow::govulncheck job must set a finite timeout-minutes (found none)"
  status=1
elif ((timeout < min_timeout)); then
  echo "::error file=$workflow::govulncheck timeout-minutes must be >= $min_timeout to survive a cold-cache scan and cache-save cleanup; got $timeout"
  status=1
fi

gomemlimit="$(yq -r '.jobs.govulncheck.env.GOMEMLIMIT // ""' "$workflow")"
if [[ -z "$gomemlimit" || "$gomemlimit" == "null" ]]; then
  echo "::error file=$workflow::govulncheck job must keep the GOMEMLIMIT heap cap so the GC stays under the host RAM ceiling"
  status=1
fi

# Ceiling sweep over every job that sets GOMEMLIMIT.
jobs_with_limit="$(yq -r '.jobs | to_entries[] | select(.value.env.GOMEMLIMIT != null) | .key + " " + .value.env.GOMEMLIMIT' "$workflow")"

checked=0
while IFS=' ' read -r job value; do
  [[ -n "$job" ]] || continue
  checked=$((checked + 1))

  if ! parser_output="$(bash "$root/.github/scripts/validate-go-memory-limit.sh" "$value" "$max_gomemlimit_gib" 2>&1)"; then
    printf '%s\n' "$parser_output"
    status=1
  fi

done <<EOF
$jobs_with_limit
EOF

# An empty sweep means the enumeration failed, not that the workflow is safe.
if ((checked == 0)); then
  echo "::error file=$workflow::found no job declaring GOMEMLIMIT; the headroom sweep examined nothing, so its result proves nothing"
  status=1
fi

if [[ "$status" -eq 0 ]]; then
  echo "govulncheck timeout ($timeout min) OK; GOMEMLIMIT ceiling ${max_gomemlimit_gib}GiB satisfied by $checked job(s)"
fi

exit "$status"
