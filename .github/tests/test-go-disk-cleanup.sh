#!/usr/bin/env bash
# Exercise actual cleanup steps; sudo is isolated so host toolchains are never removed.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
export DISK_FIXTURE="$scratch"
cat > "$scratch/bin/df" <<'DF'
#!/usr/bin/env bash
case "${DISK_CASE:-high}" in
  empty) exit 0 ;;
  partial) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 104857600 10485760 94371840 10%% /\n'; exit 7 ;;
  malformed) value=garbage ;;
  extra) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 104857600 10485760 94371840 10%% /\nextra 1 0 1 0%% /\n'; exit 0 ;;
  inconsistent) value=104857601 ;;
  low) value=1048576 ;;
  boundary) value=33554432 ;;
  high) value=94371840 ;;
  final) [[ ! -s "$DISK_FIXTURE/deletions" ]] || exit 7; value=94371840 ;;
  hung) if [[ ! -e "$DISK_FIXTURE/hung-started" ]]; then
    touch "$DISK_FIXTURE/hung-started"
    echo $$ > "$DISK_FIXTURE/hung-pid"
    trap '' TERM
    sleep 10
  fi; value=94371840 ;;
  *) exit 9 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 104857600 10485760 %s 10%% /\n' "$value"
DF
cat > "$scratch/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISK_FIXTURE/deletions"
exit "${DELETE_EXIT:-0}"
SUDO
chmod +x "$scratch/bin/df" "$scratch/bin/sudo"
export PATH="$scratch/bin:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }
for job in build test coverage; do
  yq -r ".jobs.$job.steps[] | select(.name == \"🧹 Free disk space\") | .run" "$workflow" > "$scratch/step"
  [[ -s "$scratch/step" ]] || fail "missing $job cleanup"
  for budget in 32 0; do
    for scenario in high boundary low empty partial malformed extra inconsistent; do
      : > "$scratch/deletions"
      MINIMUM_FREE_DISK_GIB="$budget" DISK_CASE="$scenario" bash -euo pipefail "$scratch/step" > "$scratch/result"
      if [[ "$budget" == 32 && ( "$scenario" == high || "$scenario" == boundary ) ]]; then
        [[ ! -s "$scratch/deletions" ]] || fail "$job reclaims despite sufficient measured capacity ($scenario)"
      else
        [[ "$(wc -l < "$scratch/deletions" | tr -d ' ')" == 1 ]] || fail "$job does not retain cleanup ($budget $scenario)"
        [[ "$(cat "$scratch/deletions")" == *"/usr/local/lib/android"*"/usr/share/miniconda"* ]] || fail 'cleanup targets changed'
      fi
      sed -n 's/^GO_DISK_CLEANUP //p' "$scratch/result" > "$scratch/receipt"
      jq -e --argjson budget "$budget" '.minimum_free_gib == $budget and (.decision == "retain" or .decision == "reclaim")' "$scratch/receipt" >/dev/null || fail 'missing attributable cleanup receipt'
      if [[ "$scenario" == empty || "$scenario" == partial || "$scenario" == malformed || "$scenario" == extra || "$scenario" == inconsistent ]]; then
        jq -e '.status == "unknown" and .decision == "reclaim" and .before_available_kib == null' "$scratch/receipt" >/dev/null || fail 'unreadable capacity authorized bypass'
      fi
    done
  done
  : > "$scratch/deletions"
  MINIMUM_FREE_DISK_GIB=0 DISK_CASE=final bash -euo pipefail "$scratch/step" > "$scratch/result"
  sed -n 's/^GO_DISK_CLEANUP //p' "$scratch/result" | jq -e '.status == "unknown" and .before_available_kib == 94371840 and .after_available_kib == null and .decision == "reclaim"' >/dev/null || fail 'failed final read claimed complete observation'
  : > "$scratch/deletions"
  rm -f "$scratch/hung-started"
  started=$SECONDS
  MINIMUM_FREE_DISK_GIB=32 DISK_CASE=hung bash -euo pipefail "$scratch/step" > "$scratch/result"
  ((SECONDS - started <= 8)) || fail 'capacity observation was not bounded'
  ! kill -0 "$(cat "$scratch/hung-pid")" 2>/dev/null || fail 'timed-out observer survived'
  [[ -s "$scratch/deletions" ]] || fail 'timed-out observation authorized bypass'
  for budget in -1 1.5 1025 abc ''; do
    : > "$scratch/deletions"
    rc=0
    MINIMUM_FREE_DISK_GIB="$budget" bash -euo pipefail "$scratch/step" > "$scratch/result" 2>&1 || rc=$?
    [[ "$rc" == 2 && ! -s "$scratch/deletions" ]] || fail "$job accepted invalid input '$budget'"
  done
  MINIMUM_FREE_DISK_GIB=0 DELETE_EXIT=1 bash -euo pipefail "$scratch/step" > /dev/null || fail 'cleanup stopped being best-effort'
done
# Native large-consumer observations must run from reviewed main without write authority.
trial="$root/.github/workflows/measure-go-disk.yaml"
yq -o=json '.' "$trial" | jq -e '
  .on.workflow_dispatch.inputs.enabled.default == false and
  .jobs.measure.if == "${{ github.ref == '\''refs/heads/main'\'' && inputs.enabled == true }}" and
  .permissions == {} and .jobs.measure.permissions == {contents:"read"} and
  .jobs.measure.strategy.matrix.phase == ["build","coverage"] and
  ([.jobs.measure.steps[]|select((.uses//"")|startswith("actions/checkout@"))|.with."persist-credentials"] == [false,false]) and
  ([.jobs.measure.steps[]|select(.with.repository == "devantler-tech/ksail")|.with.ref]|length) == 1' >/dev/null || fail 'unsafe large-consumer measurement boundary'
diff -u <(yq -r '.jobs.build.steps[] | select(.name == "🧹 Free disk space") | .run' "$workflow") \
  <(yq -r '.jobs.measure.steps[] | select(.name == "🧹 Free disk space") | .run' "$trial") || fail 'native evaluation does not exercise production cleanup'
printf 'Go disk cleanup: capacity, default, timeout, failure and invalid-input controls passed\n'
