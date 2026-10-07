#!/usr/bin/env bash
# Sample filesystem headroom while preserving the wrapped command's result.
set -euo pipefail
phase="${1:-}"
case "$phase" in build|test|coverage) shift ;; *) echo 'Invalid Go disk measurement phase' >&2; exit 2 ;; esac
[[ "$#" -gt 0 ]] || { echo 'Missing measured command' >&2; exit 2; }
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/go-disk.XXXXXX")"
monitor_pid=''
command_pid=''
# Separate process groups let cancellation stop the command's children as well.
set -m
stop_monitor() {
  if [[ -n "$monitor_pid" ]]; then
    kill -TERM -- "-$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    monitor_pid=''
  fi
}
trap 'stop_monitor; rm -rf -- "$scratch"' EXIT
# Bash invokes this handler from the INT/TERM traps below.
# shellcheck disable=SC2329
cancel() {
  trap '' INT TERM
  if [[ -n "$command_pid" ]]; then
    kill -TERM -- "-$command_pid" 2>/dev/null || true
    # A command may ignore TERM; never wait indefinitely during cancellation.
    for _ in {1..20}; do
      kill -0 -- "-$command_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
sample() {
  local frame values total used available
  # Capture the complete command before parsing: plausible stdout followed by
  # an operational failure is unknown, never an accepted partial observation.
  if ! frame="$(LC_ALL=C df -Pk . 2>/dev/null)" ||
     ! values="$(awk 'NR == 2 {print $2, $3, $4} END {if (NR != 2) exit 1}' <<< "$frame")"; then
    touch "$scratch/unknown"
    return
  fi
  if [[ ! "$values" =~ ^([0-9]{1,12})[[:space:]]([0-9]{1,12})[[:space:]]([0-9]{1,12})$ ]]; then
    touch "$scratch/unknown"
    return
  fi
  total=$((10#${BASH_REMATCH[1]})); used=$((10#${BASH_REMATCH[2]})); available=$((10#${BASH_REMATCH[3]}))
  if ((total == 0 || used > total || available > total || used + available > total)); then
    touch "$scratch/unknown"
    return
  fi
  printf '%s %s\n' "$used" "$available" >> "$scratch/samples"
}
sample
(
  trap 'exit 0' INT TERM
  while sleep 1; do sample; done
) 2>/dev/null &
monitor_pid=$!
"$@" &
command_pid=$!
rc=0
wait "$command_pid" || rc=$?
command_pid=''
# A sampler that stopped by itself cannot establish complete observations.
kill -0 "$monitor_pid" 2>/dev/null || touch "$scratch/unknown"
stop_monitor
sample
samples=0; initial=null; final=null; minimum=null; maximum=null
if [[ -f "$scratch/samples" ]]; then
  while read -r used available; do
    ((samples += 1))
    [[ "$initial" != null ]] || initial="$available"
    final="$available"
    if [[ "$minimum" == null ]] || ((available < minimum)); then minimum="$available"; fi
    if [[ "$maximum" == null ]] || ((used > maximum)); then maximum="$used"; fi
  done < "$scratch/samples"
fi
status=measured
if [[ -e "$scratch/unknown" ]] || ((samples < 2)); then
  status=unknown
  initial=null; final=null; minimum=null; maximum=null
fi
receipt="$(jq -cn --arg status "$status" --arg phase "$phase" \
  --arg run_id "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg head "${GITHUB_SHA:-}" --arg workflow_sha "${GO_DISK_WORKFLOW_SHA:-${GITHUB_WORKFLOW_SHA:-}}" --arg job "${GITHUB_JOB:-}" \
  --argjson samples "$samples" --argjson initial "$initial" --argjson final "$final" \
  --argjson minimum "$minimum" --argjson maximum "$maximum" --argjson rc "$rc" \
  '{status:$status,phase:$phase,run_id:$run_id,attempt:$attempt,head:$head,workflow_sha:$workflow_sha,job:$job,interval_seconds:1,samples:$samples,initial_available_kib:$initial,final_available_kib:$final,minimum_available_kib:$minimum,maximum_used_kib:$maximum,command_exit:$rc}')" || {
  echo '::warning::Go disk measurement UNKNOWN: receipt could not be encoded' >&2
  exit "$rc"
}
printf 'GO_DISK_USAGE %s\n' "$receipt"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Go disk usage: %s\n\nSampled filesystem headroom (1-second interval; not an exact peak).\n\n' "$phase"
    printf '%s\n' '```json' "$receipt" '```'
  } >> "$GITHUB_STEP_SUMMARY" || true
fi
exit "$rc"
