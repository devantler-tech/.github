#!/usr/bin/env bash
# Bounded retry with exponential backoff for transient-failure-prone commands.
#
# Wraps a command so a composite action's *network pull* — a Homebrew tap/install,
# a registry login, a tool/toolchain download — tolerates transient registry or
# network flakes (GHCR 5xx, DNS/TLS blips) instead of redding a *required* CI check
# on infra noise rather than a real failure. See the reliability pillar of the
# actions roadmap (devantler-tech/actions#247).
#
# Shared across composite actions and resolved relative to ${GITHUB_ACTION_PATH}
# (like .scripts/ensure-gh-skill.sh) so the retry logic lives in one place —
# composite actions cannot share steps, but they can share a bundled script that
# works for both local `uses: ./<action>` callers and external
# `uses: devantler-tech/.github/actions/<action>@<ref>` consumers.
#
# Usage:
#   bash "${GITHUB_ACTION_PATH}/../../.scripts/retry.sh" <command> [args...]
#
# Tunable via environment (sensible CI defaults):
#   RETRY_MAX_ATTEMPTS   total attempts before giving up         (default 3)
#   RETRY_BASE_DELAY     seconds to wait before the first retry  (default 5)
#   RETRY_MAX_DELAY      cap on the backoff delay in seconds     (default 60)
#
# Stdout contains only the successful attempt, with its bytes preserved. Each
# attempt is buffered so a partial failed response cannot contaminate a later
# successful JSON or state read. Command stderr remains visible immediately.
# Exit status: 0 on the first success; otherwise the failing command's last exit
# status after RETRY_MAX_ATTEMPTS attempts, so a genuine failure still reds the
# check. (No `set -e`: command failure is handled explicitly, not fatally.)
set -uo pipefail

max_attempts="${RETRY_MAX_ATTEMPTS:-3}"
base_delay="${RETRY_BASE_DELAY:-5}"
max_delay="${RETRY_MAX_DELAY:-60}"

if [ "$#" -eq 0 ]; then
  echo "::error::retry.sh: no command given" >&2
  exit 2
fi

attempt_stdout=$(umask 077; mktemp "${TMPDIR:-/tmp}/retry-stdout.XXXXXX") || exit 2
trap 'rm -f "$attempt_stdout"' EXIT
command_pid=''
launching=false
pending_interrupt=''
launch_owned() {
  local restore_monitor=false
  [[ "$-" == *m* ]] || restore_monitor=true
  launching=true
  # Job control gives this attempt its own process group on both macOS and
  # Linux. Nested installers inherit that group; no process-name search or
  # signal to the caller's group is needed when cancellation arrives.
  set -m
  "$@" <&0 >"$attempt_stdout" &
  command_pid=$!
  [[ "$restore_monitor" == false ]] || set +m
  launching=false
  [[ -z "$pending_interrupt" ]] || interrupted "$pending_interrupt"
}
interrupted() {
  # A signal can arrive between spawning and saving $!. Defer it until the
  # launch records the group identity rather than leaving an unowned child.
  if [[ "$launching" == true ]]; then
    pending_interrupt="${pending_interrupt:-$1}"
    return
  fi
  trap '' HUP INT TERM
  if [ -n "$command_pid" ]; then
    # Stop this attempt's group, including a wrapper's nested installer,
    # before removing its partial result. Then reap the owned direct child.
    kill -TERM -- "-$command_pid" 2>/dev/null || true
    kill -KILL -- "-$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'interrupted 129' HUP
trap 'interrupted 130' INT
trap 'interrupted 143' TERM

attempt=1
delay="$base_delay"
while true; do
  # An asynchronous wait lets Bash run signal traps while the command is
  # still alive. Explicit stdin preserves the wrapped command's input.
  launch_owned "$@"
  wait "$command_pid"
  status=$?
  command_pid=''
  if [ "$status" -eq 0 ]; then
    cat "$attempt_stdout"
    exit $?
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "::error::'$*' failed after ${max_attempts} attempt(s) (last exit ${status})" >&2
    exit "$status"
  fi
  echo "::warning::'$*' failed (exit ${status}); attempt ${attempt}/${max_attempts}, retrying in ${delay}s" >&2
  launch_owned sleep "$delay"
  wait "$command_pid"
  sleep_status=$?
  command_pid=''
  [ "$sleep_status" -eq 0 ] || exit "$sleep_status"
  attempt=$((attempt + 1))
  delay=$((delay * 2))
  if [ "$delay" -gt "$max_delay" ]; then
    delay="$max_delay"
  fi
done
