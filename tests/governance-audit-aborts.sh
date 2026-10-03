#!/usr/bin/env bash
# An unexpected abort must never be a successful governance observation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for auditor in check-repository-admin-teams check-repository-coverage run-governance-audits; do
  for probe in nounset failure early-success; do
    case "$probe" in
    nounset) injection=": \"\$UNSET_AUDIT_PROBE\"" ;;
    failure) injection='exit 17' ;;
    early-success) injection='exit 0' ;;
    esac
    awk -v injection="$injection" '
      {print}
      /^trap .* EXIT$/ {
        print "printf '\''%s'\'' \"$work\" > \"$PROBE_PATH\""
        print "printf '\''private-fixture'\'' > \"$work/probe-artifact\""
        print injection
        found++
      }
      END {if (found != 1) exit 99}
    ' "$root/scripts/$auditor.sh" >"$work/probe.sh"
    status=0
    env -i PATH="$PATH" PROBE_PATH="$work/path" bash "$work/probe.sh" >"$work/log" 2>&1 || status=$?
    [[ "$status" == 2 ]] || {
      echo "FAIL: $auditor $probe returned $status, expected UNKNOWN (2)" >&2
      exit 1
    }
    grep -Fq 'UNKNOWN' "$work/log" || {
      echo "FAIL: $auditor lost its incomplete observation" >&2
      exit 1
    }
    [[ -s "$work/path" && ! -e "$(cat "$work/path")" ]] || {
      echo 'FAIL: private audit temporary files remain' >&2
      exit 1
    }
    echo "PASS: $auditor classifies $probe as UNKNOWN and cleans up"
  done
done
