#!/usr/bin/env bash
# Exercise the production setup/cleanup shells. Linux CI also activates real swap.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/validate-go-project.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

setup_count="$(yq '[.jobs.govulncheck.steps[] | select(.id == "scan-swap")] | length' "$workflow")"
[[ "$setup_count" == 1 ]] || fail 'scanner must prepare swap exactly once before scanning'
yq -r '.jobs.govulncheck.steps[] | select(.id == "scan-swap") | .run' "$workflow" >"$work/setup.sh"
yq -r '.jobs.govulncheck.steps[] | select(.id == "scan-swap-cleanup") | .run' "$workflow" >"$work/cleanup.sh"
[[ -s "$work/setup.sh" && -s "$work/cleanup.sh" ]] || fail 'missing swap shells'
[[ "$(yq -r '.jobs.govulncheck.steps[] | select(.id == "scan-swap-cleanup") | .if' "$workflow")" == *'always()'* ]] || fail 'cleanup must run after failed scans too'
ids="$(yq -r '.jobs.govulncheck.steps[].id // ""' "$workflow")"
[[ "$ids" == *'scan-swap'*'scan-clock'*'scan-timeout'*'scan-swap-cleanup'* ]] || fail 'swap must span both bounded scan attempts'

export RUNNER_TEMP="$work/runner" GITHUB_OUTPUT="$work/output"
mkdir -p "$RUNNER_TEMP"
: >"$GITHUB_OUTPUT"
if [[ "${1:-}" == --live ]]; then
  [[ "$(uname -s)" == Linux ]] || fail 'live swap proof requires Linux'
  bash "$work/setup.sh"
  SWAP_FILE="$(sed -n 's/^path=//p' "$GITHUB_OUTPUT")"
  export SWAP_FILE
  [[ -n "$SWAP_FILE" ]] || fail 'setup did not publish its owned swap path'
  # Preserve cleanup even if a native assertion fails.
  trap 'bash "$work/cleanup.sh"; rm -rf "$work"' EXIT
  [[ "$(stat -c %a "$SWAP_FILE")" == 600 ]] || fail 'swap must be private'
  bytes="$(swapon --show=NAME,SIZE --bytes --json | jq -r --arg p "$SWAP_FILE" '.swapdevices[] | select(.name == $p) | .size')"
  [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -ge 4294963200 ]] || fail 'native kernel did not activate four GiB of swap'
  bash "$work/cleanup.sh"
  [[ ! -e "$SWAP_FILE" ]] || fail 'native cleanup left its file behind'
  trap 'rm -rf "$work"' EXIT
  echo 'PASS: native kernel swap activation, private mode and cleanup'
  exit 0
fi

# Only privileged Linux host operations are substituted on the macOS agent host.
# Real mktemp/files and the actual production shells execute in every case.
mkdir -p "$work/bin"
export SWAP_TEST_STATE="$work/state" SWAP_TEST_LOG="$work/calls"
cat >"$work/bin/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
cat >"$work/bin/df" <<'SH'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 20000000 0 %s 0%% /\n' "${SWAP_TEST_FREE_KIB:-16000000}"
SH
cat >"$work/bin/fallocate" <<'SH'
#!/usr/bin/env bash
printf 'allocate %s\n' "$*" >>"$SWAP_TEST_LOG"
[[ "$1" == -l && "$2" == 4294967296 && "$3" == -- && -f "$4" ]] || exit 90
[[ "${SWAP_TEST_FAIL:-}" != allocate ]]
SH
cat >"$work/bin/mkswap" <<'SH'
#!/usr/bin/env bash
[[ "${SWAP_TEST_FAIL:-}" != format ]]
SH
cat >"$work/bin/swapon" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == --show=NAME ]]; then
  [[ "${SWAP_TEST_FAIL:-}" != readback ]] && cat "$SWAP_TEST_STATE"
else
  [[ "${SWAP_TEST_FAIL:-}" != activate ]] || exit 1
  printf '%s\n' "${!#}" >"$SWAP_TEST_STATE"
fi
SH
cat >"$work/bin/swapoff" <<'SH'
#!/usr/bin/env bash
rm -f "$SWAP_TEST_STATE"
SH
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

bash "$work/setup.sh"
SWAP_FILE="$(sed -n 's/^path=//p' "$GITHUB_OUTPUT")"
export SWAP_FILE
[[ -f "$SWAP_FILE" && "$(cat "$SWAP_TEST_STATE")" == "$SWAP_FILE" ]] || fail 'setup did not activate its owned file'
if [[ "$(uname -s)" == Darwin ]]; then mode="$(stat -f %Lp "$SWAP_FILE")"; else mode="$(stat -c %a "$SWAP_FILE")"; fi
[[ "$mode" == 600 ]] || fail 'swap file permissions are not private'
bash "$work/cleanup.sh"
[[ ! -e "$SWAP_FILE" && ! -e "$SWAP_TEST_STATE" ]] || fail 'cleanup failed to retire owned swap'
echo 'PASS: prepare, confirm and retire owned swap'

for failure in allocate format activate readback; do
  export SWAP_TEST_FAIL="$failure"
  : >"$GITHUB_OUTPUT"
  if bash "$work/setup.sh" >"$work/failure.log" 2>&1; then fail "$failure must fail the preflight"; fi
  [[ ! -s "$GITHUB_OUTPUT" ]] || fail "$failure published unverified swap"
  [[ ! -e "$SWAP_TEST_STATE" ]] || fail "$failure left active swap behind"
  echo "PASS: $failure cannot publish successful preparation"
done
unset SWAP_TEST_FAIL
export SWAP_TEST_FREE_KIB=8000000
: >"$GITHUB_OUTPUT"
: >"$SWAP_TEST_LOG"
if bash "$work/setup.sh" >"$work/failure.log" 2>&1; then fail 'insufficient disk must fail before allocation'; fi
grep -q 'Insufficient disk' "$work/failure.log" || fail 'disk refusal failed for another reason'
[[ ! -s "$SWAP_TEST_LOG" && ! -s "$GITHUB_OUTPUT" ]] || fail 'disk refusal allocated or published swap'
echo 'PASS: insufficient disk fails before allocation'
