#!/usr/bin/env bash
# Same decimal, unit and overflow checks for workflow lint and runtime preflight.
set -euo pipefail
value="${1-}"
max_gomemlimit_gib="${2:-8}"
workflow=memory-limit
job=analysis
status=0
if [[ ! "$max_gomemlimit_gib" =~ ^[0-9]{1,9}$ ]]; then
  echo "::error::GOMEMLIMIT ceiling must be 1-9 decimal digits so it cannot reach an arithmetic context unchecked; got '$max_gomemlimit_gib'"
  exit 1
fi
max_gomemlimit_gib=$((10#$max_gomemlimit_gib))
if ((max_gomemlimit_gib == 0)); then
  echo "::error::GOMEMLIMIT ceiling must be greater than zero; got '0'"
  exit 1
fi

# Parse the SAME WAY GO DOES: decimally, always. Bash arithmetic treats a
# leading zero as octal, so a bare $((gib * 1024)) reads `010GiB` as 8192 MiB
# and waves it through the ceiling — while the Go runtime reads that exact
# string as 10 GiB (measured: debug.SetMemoryLimit reports 10737418240). The
# `10#` prefix removes the divergence, and it also stops `08GiB` — a value Go
# accepts as 8 GiB — from aborting the arithmetic with "value too great for
# base" and leaving the comparison unrun.
# Parse Go's OWN accepted set: a byte count, optionally suffixed B, KiB, MiB,
# GiB or TiB (pkg.go.dev/runtime, GOMEMLIMIT). A guard that recognises a
# narrower set than the runtime fails a build over a limit that was always
# valid — the same divergence, in the opposite direction, as reading 010GiB as
# octal. Comparison is in bytes so a sub-MiB unit cannot round to zero.
value_bytes=""
if [[ "$value" =~ ^([0-9]+)(B|KiB|MiB|GiB|TiB)?$ ]]; then
  digits="${BASH_REMATCH[1]}"
  # Go parses the digit string decimally, so leading zeros carry no magnitude:
  # `000000000000000000008GiB` is exactly 8 GiB (measured — debug.SetMemoryLimit
  # reports 8589934592 for that spelling and for a plain `8GiB`). The per-unit
  # bound below exists to keep `digits * multiplier` clear of the 64-bit wrap,
  # which is a property of the VALUE and not of its padding, so normalise the
  # padding away before counting. Without this the guard fails a build over a
  # limit that is both valid Go and under the ceiling — the same runtime-vs-guard
  # divergence the `10#` prefix removes, one level down.
  digits="${digits#"${digits%%[!0]*}"}"
  digits="${digits:-0}"
  unit="${BASH_REMATCH[2]:-B}"

  # Bound the digit count BEFORE any arithmetic, PER UNIT. Bash integers are
  # 64-bit and wrap silently: 18014398509481985 * 1024 evaluates to 1024, and
  # 9223372036854775807 * 1024 to -1024 — both sail under the ceiling. Each
  # bound below keeps digits * multiplier under 2^62, and every one of them is
  # already far beyond any real runner.
  case "$unit" in
  B) multiplier=1 max_digits=18 ;;
  KiB) multiplier=1024 max_digits=15 ;;
  MiB) multiplier=1048576 max_digits=12 ;;
  GiB) multiplier=1073741824 max_digits=9 ;;
  TiB) multiplier=1099511627776 max_digits=6 ;;
  *)
    echo "::error file=$workflow::job '$job' GOMEMLIMIT unit '$unit' has no conversion; refusing to report the headroom check as passed"
    status=1
    multiplier=0 max_digits=0
    ;;
  esac

  if ((multiplier == 0)); then
    : # already reported above; leave value_bytes empty so the check fails closed
  elif ((${#digits} > max_digits)); then
    echo "::error file=$workflow::job '$job' GOMEMLIMIT '$value' is implausibly large; refusing to convert it, because fixed-width arithmetic on a value this size wraps and would report the headroom check as passed"
    status=1
  else
    value_bytes=$((10#$digits * multiplier))
  fi
else
  echo "::error file=$workflow::job '$job' GOMEMLIMIT must be an integer optionally suffixed B, KiB, MiB, GiB or TiB (the set Go accepts) so its headroom can be checked; got '$value'"
  status=1
fi

# Fail closed: a value that did not parse to a plain integer must never skip
# the comparison and be reported as passing.
if [[ -n "$value_bytes" && ! "$value_bytes" =~ ^[0-9]+$ ]]; then
  echo "::error file=$workflow::job '$job' GOMEMLIMIT parsed to a non-numeric size ('$value_bytes') from '$value'; refusing to report the headroom check as passed"
  status=1
  value_bytes=""
fi

if [[ -n "$value_bytes" ]] && ((value_bytes > max_gomemlimit_gib * 1073741824)); then
  echo "::error file=$workflow::job '$job' GOMEMLIMIT must be <= ${max_gomemlimit_gib}GiB to leave the host headroom GOMEMLIMIT does not govern (runner agent, harden-runner, go subprocesses); got $value. Above this the host OOM-kills the runner mid-analysis with an opaque exit 143."
  status=1
fi
[[ "$status" == 0 ]] || exit 1
printf '%s\n' "$value_bytes"
