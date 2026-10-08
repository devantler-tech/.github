#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/validate-go-project.yaml"
fail() { echo "::error::$*" >&2; exit 1; }
[[ "$(yq -r '.on.workflow_call.inputs.measure-disk-usage.default' "$workflow")" == false ]] || fail 'Go disk collection must be explicitly default-off'
script="$root/.github/scripts/measure-go-disk.sh"
[[ -f "$script" ]] || fail 'Go disk collection has no executable implementation'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat > "$scratch/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$DISK_FIXTURE/count" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$DISK_FIXTURE/count"
case "${DISK_CASE:-clean}" in
  partial) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 10000 2000 8000 20%% /\n'; exit 7 ;;
  malformed) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 10000 2000 nonsense 20%% /\n'; exit 0 ;;
  empty) exit 0 ;;
  intermediate) if [[ "$n" == 2 ]]; then exit 9; fi ;;
  final) if [[ -e "$DISK_FIXTURE/finished" ]]; then exit 9; fi ;;
  resistant) if [[ "$n" == 2 ]]; then trap '' TERM; echo $$ > "$DISK_FIXTURE/sampler-pid"; sleep 10; fi ;;
  initial-resistant) if [[ "$n" == 1 ]]; then trap '' TERM; echo $$ > "$DISK_FIXTURE/edge-pid"; sleep 10; fi ;;
  final-resistant) if [[ -e "$DISK_FIXTURE/finished" ]]; then trap '' TERM; echo $$ > "$DISK_FIXTURE/edge-pid"; sleep 10; fi ;;
esac
available=8000; used=2000
if [[ -e "$DISK_FIXTURE/allocated" ]]; then available=3000; used=7000; fi
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 10000 %s %s 20%% /\n' "$used" "$available"
EOF
chmod +x "$scratch/bin/df"
export DISK_FIXTURE="$scratch" PATH="$scratch/bin:$PATH"
# Refuse a consumer-owned checkout path before checkout can replace its files.
mkdir "$scratch/collision"
for job in build test coverage; do
  JOB_ID="$job" yq -o=json '.jobs[strenv(JOB_ID)].steps' "$workflow" | jq -e '
    [to_entries[] | select(.value.name == "Reserve disk measurement checkout path")] as $guards |
    [to_entries[] | select(.value.name == "Checkout disk measurement helper")] as $checkouts |
    ($guards | length) == 1 and ($checkouts | length) == 1 and
    $guards[0].key < $checkouts[0].key and
    $guards[0].value.if == $checkouts[0].value.if' >/dev/null || fail "$job must guard before its same-condition checkout"
  yq -r ".jobs.$job.steps[] | select(.name == \"Reserve disk measurement checkout path\") | .run" "$workflow" > "$scratch/reserve"
  [[ -s "$scratch/reserve" ]] || fail "$job has no checkout collision guard"
  GITHUB_WORKSPACE="$scratch/collision" bash -euo pipefail "$scratch/reserve"
  mkdir "$scratch/collision/.devantler-tech-go-disk"
  printf 'consumer\n' > "$scratch/collision/.devantler-tech-go-disk/subject"
  if GITHUB_WORKSPACE="$scratch/collision" bash -euo pipefail "$scratch/reserve"; then fail "$job accepted a consumer-owned directory"; fi
  [[ "$(cat "$scratch/collision/.devantler-tech-go-disk/subject")" == consumer ]] || fail "$job changed existing consumer files"
  rm -rf "$scratch/collision/.devantler-tech-go-disk"
  ln -s missing "$scratch/collision/.devantler-tech-go-disk"
  if GITHUB_WORKSPACE="$scratch/collision" bash -euo pipefail "$scratch/reserve"; then fail "$job accepted a dangling consumer symlink"; fi
  [[ -L "$scratch/collision/.devantler-tech-go-disk" ]] || fail "$job changed the existing symlink"
  rm "$scratch/collision/.devantler-tech-go-disk"
done
run_case() {
  rm -f "$scratch/count" "$scratch/allocated"
  local want="$1"; shift
  local rc=0
  bash "$script" "$@" > "$scratch/result" 2> "$scratch/stderr" || rc=$?
  [[ "$rc" == "$want" ]] || fail "command status changed: wanted $want, got $rc"
  sed -n 's/^GO_DISK_USAGE //p' "$scratch/result" > "$scratch/receipt.json"
  jq -e 'type == "object"' "$scratch/receipt.json" > /dev/null || fail 'missing measurement receipt'
}
# A transient allocation must remain visible after the command removes it.
run_case 0 build bash -c "touch \"\$DISK_FIXTURE/allocated\"; sleep 2; rm \"\$DISK_FIXTURE/allocated\""
jq -e '.status == "measured" and .initial_available_kib == 8000 and .minimum_available_kib == 3000 and .maximum_used_kib == 7000 and .final_available_kib == 8000 and .samples >= 3 and .interval_seconds == 1 and .command_exit == 0' "$scratch/receipt.json" >/dev/null || fail 'transient disk pressure was lost'
run_case 23 test bash -c 'exit 23'
jq -e '.command_exit == 23' "$scratch/receipt.json" >/dev/null || fail 'failed command reported success'
for DISK_CASE in initial-resistant final-resistant; do
  export DISK_CASE
  rm -f "$scratch/finished"
  edge_started=$SECONDS
  run_case 23 test bash -c "touch \"\$DISK_FIXTURE/finished\"; exit 23"
  ((SECONDS - edge_started <= 6)) || fail "$DISK_CASE disk read blocked the wrapped command's result"
  ! kill -0 "$(cat "$scratch/edge-pid")" 2>/dev/null || fail "$DISK_CASE child survived collection"
  jq -e '.status == "unknown" and .command_exit == 23 and .minimum_available_kib == null' "$scratch/receipt.json" >/dev/null || fail "$DISK_CASE left incomplete capacity evidence"
done
unset DISK_CASE
rm -f "$scratch/finished"
# A blocked df must not keep a completed command waiting indefinitely.
shutdown_started=$SECONDS
DISK_CASE=resistant run_case 0 test bash -c 'sleep 2'
((SECONDS - shutdown_started <= 6)) || fail 'sampler shutdown exceeded its bounded grace period'
! kill -0 "$(cat "$scratch/sampler-pid")" 2>/dev/null || fail 'resistant sampler child survived normal shutdown'
jq -e '.status == "unknown" and .minimum_available_kib == null' "$scratch/receipt.json" >/dev/null || fail 'forced sampler shutdown claimed complete measurement'
# Observation storage is optional: it must never replace the Go result.
real_mktemp="$(command -v mktemp)"
export REAL_MKTEMP="$real_mktemp"
cat > "$scratch/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "${DISK_STORAGE_CASE:-}" in
  unavailable) exit 1 ;;
  unwritable)
    directory=$("$REAL_MKTEMP" "$@") || exit $?
    : > "$directory/samples"
    chmod 444 "$directory/samples"
    printf '%s\n' "$directory"
    ;;
  *) exec "$REAL_MKTEMP" "$@" ;;
esac
EOF
chmod +x "$scratch/bin/mktemp"
for DISK_STORAGE_CASE in unavailable unwritable; do
  export DISK_STORAGE_CASE
  rm -f "$scratch/command-ran"
  run_case 23 test bash -c "echo run >> \"\$DISK_FIXTURE/command-ran\"; exit 23"
  [[ "$(cat "$scratch/command-ran")" == run ]] || fail 'storage failure skipped or repeated the command'
  jq -e '.status == "unknown" and .command_exit == 23 and .initial_available_kib == null and .final_available_kib == null and .minimum_available_kib == null and .maximum_used_kib == null' "$scratch/receipt.json" >/dev/null || fail 'storage failure left misleading capacity evidence'
done
unset DISK_STORAGE_CASE
for DISK_CASE in partial malformed empty intermediate; do
  export DISK_CASE
  run_case 0 coverage bash -c 'sleep 2'
  jq -e '.status == "unknown" and .minimum_available_kib == null and .maximum_used_kib == null' "$scratch/receipt.json" >/dev/null || fail "$DISK_CASE observation was accepted as measured"
done
unset DISK_CASE
DISK_CASE=final run_case 0 test bash -c "touch \"\$DISK_FIXTURE/finished\""
jq -e '.status == "unknown" and .initial_available_kib == null and .final_available_kib == null' "$scratch/receipt.json" >/dev/null || fail 'final read failure left partial capacity evidence'
rm "$scratch/finished"
# Exercise the actual preparation step, keeping the helper outside module scope.
for job in build test coverage; do
  mkdir -p "$scratch/workspace/.devantler-tech-go-disk/.github/scripts" "$scratch/runner"
  cp "$script" "$scratch/workspace/.devantler-tech-go-disk/.github/scripts/measure-go-disk.sh"
  printf 'consumer\n' > "$scratch/workspace/subject"
  yq -r ".jobs.$job.steps[] | select(.name == \"Prepare disk measurement outside the consumer workspace\") | .run" "$workflow" > "$scratch/prepare"
  [[ -s "$scratch/prepare" ]] || fail "$job has no helper preparation"
  GITHUB_WORKSPACE="$scratch/workspace" RUNNER_TEMP="$scratch/runner" bash -euo pipefail "$scratch/prepare"
  [[ ! -e "$scratch/workspace/.devantler-tech-go-disk" && -x "$scratch/runner/measure-go-disk.sh" && "$(cat "$scratch/workspace/subject")" == consumer ]] || fail "$job left the helper in module scope or changed the consumer"
done
# The disabled production steps must run Go directly even with no installed collector.
cat > "$scratch/bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISK_FIXTURE/go-args"
exit "${GO_FIXTURE_EXIT:-0}"
EOF
chmod +x "$scratch/bin/go"
for job in build test coverage; do
  yq -r ".jobs.$job.steps[] | select(.name == \"🛠️ Build\" or .name == \"🧪 Test\" or .name == \"📄 Generate coverage\") | .run" "$workflow" > "$scratch/step"
  [[ -s "$scratch/step" ]] || fail "$job lacks the measurement switch"
  MEASURE_DISK_USAGE=false RUNNER_TEMP="$scratch/missing" bash -euo pipefail "$scratch/step"
done
diff -u <(printf '%s\n' 'build -v ./...' 'test ./...' 'test -race -coverprofile=coverage.txt -covermode=atomic ./...') "$scratch/go-args" || fail 'disabled path changed Go commands'
# Cancellation must stop both the command process group and its sampler.
rm -f "$scratch/count"
bash "$script" test bash -c 'trap "" TERM; echo $$ > "$DISK_FIXTURE/command-pid"; sleep 8' > "$scratch/cancel-result" 2> "$scratch/cancel-stderr" &
collector=$!
for _ in {1..40}; do [[ -s "$scratch/command-pid" ]] && break; sleep 0.1; done
[[ -s "$scratch/command-pid" ]] || fail 'cancellation command never started'
cancel_started=$SECONDS
kill -TERM "$collector"
rc=0; wait "$collector" || rc=$?
[[ "$rc" == 143 ]] || fail "cancellation returned $rc instead of 143"
((SECONDS - cancel_started <= 5)) || fail 'cancellation waited for a resistant command instead of stopping it'
! kill -0 "$(cat "$scratch/command-pid")" 2>/dev/null || fail 'command survived cancellation'
count=$(cat "$scratch/count"); sleep 2
[[ "$(cat "$scratch/count")" == "$count" ]] || fail 'sampler survived cancellation'
# Cancellation while df is blocked must stop its children too, both before
# command admission and while the background sampler is running.
for DISK_CASE in initial-resistant resistant; do
  export DISK_CASE
  rm -f "$scratch/count" "$scratch/edge-pid" "$scratch/sampler-pid" "$scratch/command-pid"
  bash "$script" test bash -c 'trap "" TERM; echo $$ > "$DISK_FIXTURE/command-pid"; sleep 8' > "$scratch/cancel-result" 2> "$scratch/cancel-stderr" &
  collector=$!
  blocked_pid="$scratch/edge-pid"
  [[ "$DISK_CASE" != resistant ]] || blocked_pid="$scratch/sampler-pid"
  for _ in {1..40}; do [[ -s "$blocked_pid" ]] && break; sleep 0.1; done
  [[ -s "$blocked_pid" ]] || fail "$DISK_CASE cancellation never reached the blocked observation"
  cancel_started=$SECONDS
  kill -TERM "$collector"
  rc=0; wait "$collector" || rc=$?
  [[ "$rc" == 143 ]] || fail "$DISK_CASE cancellation changed status to $rc"
  ((SECONDS - cancel_started <= 6)) || fail "$DISK_CASE cancellation exceeded its cleanup budget"
  ! kill -0 "$(cat "$blocked_pid")" 2>/dev/null || fail "$DISK_CASE df survived cancellation"
  if [[ -s "$scratch/command-pid" ]]; then
    ! kill -0 "$(cat "$scratch/command-pid")" 2>/dev/null || fail "$DISK_CASE command survived cancellation"
  fi
done
unset DISK_CASE
# Incomplete cleanup observations cannot justify skipping the production cleanup.
for phase in cleanup-build cleanup-test cleanup-coverage; do
  DISK_CASE=partial run_case 23 "$phase" bash -c 'exit 23'
  jq -e '.status == "unknown" and .command_exit == 23 and .initial_available_kib == null and .final_available_kib == null' "$scratch/receipt.json" >/dev/null || fail "$phase accepted a failed cleanup observation"
done
bash "$root/.github/tests/go-disk-step-contract.sh" "$root/.github/workflows/validate-go-project-readonly.yaml"
# Missing observers, missing identities and preparation after cleanup must be rejected.
for mutation in late-preparation missing-identity missing-invocation; do
  case "$mutation" in
    late-preparation)
      expression='.jobs.build.steps |= (map(select(.name != "Prepare disk measurement outside the consumer workspace")) + map(select(.name == "Prepare disk measurement outside the consumer workspace")))'
      ;;
    missing-identity)
      expression='(.jobs.build.steps[] | select(.name == "🧹 Free disk space") | .env) |= del(.GO_DISK_WORKFLOW_SHA)'
      ;;
    missing-invocation)
      expression='(.jobs.build.steps[] | select(.name == "🧹 Free disk space") | .run) |= sub("bash.*measure-go-disk.sh.*cleanup-build.*", "cleanup_disk")'
      ;;
  esac
  yq "$expression" "$workflow" > "$scratch/mutant.yaml"
  if bash "$root/.github/tests/go-disk-step-contract.sh" "$scratch/mutant.yaml" > "$scratch/mutant-result" 2>&1; then
    fail "$mutation regression went undetected"
  fi
done
echo 'Go disk measurement behavior passed'
bash "$root/.github/tests/go-disk-step-contract.sh"
