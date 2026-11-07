#!/usr/bin/env bash
# Go's work directory (packages in flight and every linked test binary) must live on
# the runner disk, not in a system temporary directory that some runner images mount
# as a small, separate tmpfs (#838). Checks the step's placement in every Go job of the
# production workflow and its read-only projection, then executes the production step
# with fake filesystem readers: the route, its before/after capacity receipt, and its
# refusal controls.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "::error::$*" >&2; exit 1; }
step_name='Route Go temporary storage to the runner disk'

for workflow in "$root/.github/workflows/validate-go-project.yaml" "$root/.github/workflows/validate-go-project-readonly.yaml"; do
  for job in build test coverage; do
    JOB_ID="$job" STEP="$step_name" yq -o=json '.jobs[strenv(JOB_ID)].steps' "$workflow" | jq -e --arg step "$step_name" '
      [to_entries[] | select(.value.name == $step)] as $route |
      [to_entries[] | select(.value.name == "🧹 Free disk space")] as $cleanup |
      [to_entries[] | select(.value.name == "⚙️ Setup Go")] as $setup |
      ($route|length) == 1 and ($cleanup|length) == 1 and ($setup|length) == 1 and
      $cleanup[0].key < $route[0].key and $route[0].key < $setup[0].key and
      ($route[0].value.if == null) and ($route[0].value.shell == "bash") and
      ($route[0].value["continue-on-error"] == null)
    ' >/dev/null || fail "$(basename "$workflow") $job must route Go temporary storage unconditionally after cleanup and before Setup Go"
    JOB_ID="$job" STEP="$step_name" yq -r '.jobs[strenv(JOB_ID)].steps[] | select(.name == strenv(STEP)) | .run' "$workflow" > "$scratch/$job.run"
  done
  if ! cmp -s "$scratch/build.run" "$scratch/test.run" || ! cmp -s "$scratch/build.run" "$scratch/coverage.run"; then
    fail "$(basename "$workflow") must run one identical route step in build, test and coverage"
  fi
done
step="$scratch/build.run"
# The route moves only the go command's work directory; test temporary directories stay put.
if grep -E '(^|[^A-Z_])TMPDIR=' "$step" >/dev/null; then fail 'The route must not change TMPDIR for the tests themselves'; fi

mkdir "$scratch/bin"
# The only external boundaries are the filesystem readers; both are fixtures.
cat > "$scratch/bin/df" <<'DF'
#!/usr/bin/env bash
[[ "${ROUTE_DF_EXIT:-0}" == 0 ]] || exit "$ROUTE_DF_EXIT"
[[ "$1" == -Pk && $# == 2 ]] || exit 2
case "$2" in
  "$ROUTE_SYSTEM_TEMP") available=6553600 ;;
  "$RUNNER_TEMP/go-tmp") available=40473804 ;;
  *) exit 2 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 160000000 1000 %s 1%% /\n' "$available"
DF
cat > "$scratch/bin/findmnt" <<'FINDMNT'
#!/usr/bin/env bash
[[ "${ROUTE_FINDMNT_EXIT:-0}" == 0 ]] || exit "$ROUTE_FINDMNT_EXIT"
[[ "$*" == "-n -o FSTYPE --target $ROUTE_SYSTEM_TEMP" ]] && { printf '%s\n' "${ROUTE_SYSTEM_FSTYPE:-tmpfs}"; exit 0; }
[[ "$*" == "-n -o FSTYPE --target $RUNNER_TEMP/go-tmp" ]] && { printf 'ext4\n'; exit 0; }
exit 2
FINDMNT
chmod +x "$scratch/bin/"*

run_route() {
  local case="$1"; shift
  mkdir -p "$scratch/$case/runner-temp" "$scratch/$case/system-temp"
  : > "$scratch/$case/env"
  rc=0
  env PATH="$scratch/bin:$PATH" RUNNER_TEMP="$scratch/$case/runner-temp" GITHUB_ENV="$scratch/$case/env" \
    TMPDIR="$scratch/$case/system-temp" ROUTE_SYSTEM_TEMP="$scratch/$case/system-temp" "$@" \
    bash -euo pipefail "$step" > "$scratch/$case/out" 2> "$scratch/$case/err" || rc=$?
}
receipt() { sed -n 's/^GO_TEMP_ROUTE //p' "$scratch/$1/out"; }

# A measured route records both filesystems and exports only the routed work directory.
run_route measured
[[ "$rc" == 0 ]] || fail "measured route exited $rc: $(cat "$scratch/measured/err")"
[[ "$(cat "$scratch/measured/env")" == "GOTMPDIR=$scratch/measured/runner-temp/go-tmp" ]] || fail 'measured route must export exactly GOTMPDIR'
[[ -d "$scratch/measured/runner-temp/go-tmp" ]] || fail 'measured route must create the work directory'
receipt measured | jq -e '. == {"status":"measured","system_temp_fstype":"tmpfs","system_temp_available_kib":6553600,"go_temp_fstype":"ext4","go_temp_available_kib":40473804}' >/dev/null ||
  fail "measured receipt is wrong: $(receipt measured)"

# Unreadable capacity is reported as unknown and never withholds the route.
run_route unread ROUTE_DF_EXIT=31 ROUTE_FINDMNT_EXIT=32
[[ "$rc" == 0 ]] || fail "unknown capacity must not fail the route (exit $rc)"
[[ "$(cat "$scratch/unread/env")" == "GOTMPDIR=$scratch/unread/runner-temp/go-tmp" ]] || fail 'unknown capacity must still route'
receipt unread | jq -e '. == {"status":"unknown","system_temp_fstype":"unknown","system_temp_available_kib":null,"go_temp_fstype":"unknown","go_temp_available_kib":null}' >/dev/null ||
  fail "unknown receipt is wrong: $(receipt unread)"

# An unexpected filesystem name is never echoed into the receipt verbatim.
run_route hostile 'ROUTE_SYSTEM_FSTYPE=tmpfs","x":"y'
[[ "$rc" == 0 ]] || fail "hostile fstype exited $rc"
receipt hostile | jq -e '.system_temp_fstype == "unknown" and (keys|length) == 5' >/dev/null || fail "hostile fstype leaked: $(receipt hostile)"

# Refusals: no runner temp, a relative or multi-line one, an occupied path, an unwritable environment file.
for refusal in missing relative multiline occupied env-unwritable; do
  mkdir -p "$scratch/$refusal/runner-temp" "$scratch/$refusal/system-temp"
  : > "$scratch/$refusal/env"
  runner_temp="$scratch/$refusal/runner-temp"; github_env="$scratch/$refusal/env"
  case "$refusal" in
    missing) runner_temp='' ;;
    relative) runner_temp='runner-temp' ;;
    multiline) runner_temp="$scratch/$refusal/runner-temp"$'\n'"/elsewhere" ;;
    occupied) : > "$scratch/$refusal/runner-temp/go-tmp" ;;
    env-unwritable) github_env="$scratch/$refusal" ;;
  esac
  rc=0
  (cd "$scratch/$refusal" && env PATH="$scratch/bin:$PATH" RUNNER_TEMP="$runner_temp" GITHUB_ENV="$github_env" \
    TMPDIR="$scratch/$refusal/system-temp" ROUTE_SYSTEM_TEMP="$scratch/$refusal/system-temp" \
    bash -euo pipefail "$step") > /dev/null 2>&1 || rc=$?
  [[ "$rc" != 0 ]] || fail "$refusal must fail the job"
  [[ ! -s "$scratch/$refusal/env" ]] || fail "$refusal must not export a route"
done
[[ ! -e "$scratch/relative/runner-temp/go-tmp" && ! -e "$scratch/relative/runner-temp/runner-temp" ]] || fail 'relative runner temp must not create a directory'

echo 'Go temporary storage routing: placement, receipt and refusal controls hold'
