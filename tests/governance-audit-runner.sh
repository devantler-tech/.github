#!/usr/bin/env bash
# Execute the real coordinator with isolated auditor processes and private diagnostics.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/scripts"
cp "$root/scripts/run-governance-audits.sh" "$work/scripts/run-governance-audits.sh"
cat >"$work/scripts/check-repository-admin-teams.sh" <<'SH'
#!/usr/bin/env bash
printf 'admin\n' >> "$CALLS"
exit "$ADMIN_STATUS"
SH
cat >"$work/scripts/check-repository-coverage.sh" <<'SH'
#!/usr/bin/env bash
printf 'coverage\n' >> "$CALLS"
echo 'PRIVATE_COVERAGE_SENTINEL' >&2
exit "$COVERAGE_STATUS"
SH
for row in '0 0 0 PASS' '0 1 1 DRIFT' '0 2 2 UNKNOWN' '0 44 2 UNKNOWN' '1 0 1 none' '2 0 2 none'; do
  read -r admin coverage want marker <<<"$row"
  : >"$work/calls"
  status=0
  env -i PATH="$PATH" CALLS="$work/calls" ADMIN_STATUS="$admin" COVERAGE_STATUS="$coverage" \
    bash "$work/scripts/run-governance-audits.sh" >"$work/log" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || {
    echo "FAIL: coordinator returned $status, expected $want" >&2
    exit 1
  }
  ! grep -q 'PRIVATE_COVERAGE_SENTINEL' "$work/log" || {
    echo 'FAIL: private coverage diagnostics escaped' >&2
    exit 1
  }
  if [[ "$admin" == 0 ]]; then
    [[ "$(cat "$work/calls")" == $'admin\ncoverage' ]] || {
      echo 'FAIL: incomplete auditor sequence' >&2
      exit 1
    }
    grep -Fq "$marker" "$work/log" || {
      echo 'FAIL: missing classified outcome' >&2
      exit 1
    }
  else
    [[ "$(cat "$work/calls")" == admin ]] || {
      echo 'FAIL: ran coverage after failed admin evidence' >&2
      exit 1
    }
    ! grep -q 'PASS' "$work/log" || {
      echo 'FAIL: partial audit passed' >&2
      exit 1
    }
  fi
  echo "PASS: admin=$admin coverage=$coverage"
done
