#!/usr/bin/env bash
# Exercise the shipped observer against real Git state and controlled OS failures.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/.github/scripts/measure-go-disk.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
fail() {
  printf 'go-disk-observation: %s\n' "$*" >&2
  exit 1
}
mkdir "$scratch/repo"
cd "$scratch/repo"
git init -q
printf '%s\n' '{"version":1,"test":true}' >.go-disk-observation.json
git add -- .go-disk-observation.json
# Removing the declaration reader or ignoring a tracked opt-in loses ordinary-run evidence.
result="$(bash "$script" select . optional)" || fail 'tracked Test observation was not admitted'
[[ "$result" == true ]] || fail 'tracked Test observation was not enabled'
printf '%s\n' '{"arbitraryPath":"/private/fixture"}' >.go-disk-observation.json
[[ "$(bash "$script" select missing/linked disabled)" == false ]] || fail 'called disabled state inspected declaration data'
for declaration in \
  '{"version":1,"test":true,"path":"/private/fixture"}' \
  '{"version":1,"test":true,"test":false}' \
  '{"version":1,"test":"true"}' \
  '{"version":1,"test":true} {}'; do
  printf '%s\n' "$declaration" >.go-disk-observation.json
  if bash "$script" select . optional >"$scratch/result" 2>"$scratch/error"; then fail 'unsafe declaration enabled observation'; fi
  [[ ! -s "$scratch/result" ]] || fail 'refusal published positive observation output'
  ! grep -F '/private/fixture' "$scratch/error" >/dev/null || fail 'declaration contents escaped through diagnostics'
done
printf '%s\n' '{"version":1,"test":false}' >.go-disk-observation.json
[[ "$(bash "$script" select . optional)" == false ]] || fail 'explicit disabled declaration enabled observation'
rm .go-disk-observation.json
if bash "$script" select . optional >"$scratch/result" 2>/dev/null; then fail 'missing tracked declaration was accepted'; fi
git rm -q --cached -- .go-disk-observation.json
[[ "$(bash "$script" select . optional)" == false ]] || fail 'absent declaration did not remain off'
printf '%s\n' '{"version":1,"test":true}' >.go-disk-observation.json
if bash "$script" select . optional >"$scratch/result" 2>/dev/null; then fail 'untracked declaration was accepted'; fi
git add -- .go-disk-observation.json
mv .go-disk-observation.json "$scratch/target"
ln -s "$scratch/target" .go-disk-observation.json
if bash "$script" select . optional >"$scratch/result" 2>/dev/null; then fail 'linked declaration was accepted'; fi
printf 'Go disk observation declaration controls passed\n'
# Execute the production admission decision: a caller's false/omitted input
# cannot inherit an input-free required invocation's module-local declaration.
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
yq -r '.jobs.changes.steps[] | select(.id == "disk-observation-mode") | .run' "$workflow" >"$scratch/mode"
[[ -s "$scratch/mode" ]] || fail 'ordinary required Test has no observation admission'
for direct in false true; do
  : >"$scratch/mode-output"
  DIRECT_REQUIRED_RUN="$direct" OBSERVATION_MODULE=. GITHUB_OUTPUT="$scratch/mode-output" bash -euo pipefail "$scratch/mode"
  want=disabled
  [[ "$direct" != true ]] || want=optional
  grep -Fx "mode=$want" "$scratch/mode-output" >/dev/null || fail 'called workflow inherited the required-run declaration'
done
yq -o=json '.jobs.test.steps' "$workflow" | jq -e '
  any(.[];.name=="Observe Go storage after setup" and .if=="${{ needs.changes.outputs.disk-observation == '\''true'\'' }}") and
  any(.[];.name=="Observe Go storage after restore" and .env.GO_DISK_MODULE_PRIMARY_KEY=="${{ steps.go-mod-cache.outputs.cache-primary-key }}" and
    .env.GO_DISK_BUILD_MATCHED_KEY=="${{ steps.go-build-cache.outputs.cache-matched-key }}") and
  any(.[];.name=="Upload Go storage observation" and .with.path=="${{ runner.temp }}/go-disk-observation/public/report.json")' \
  >/dev/null || fail 'ordinary Test lacks bound phases/cache provenance or sanitised artifact selection'
cd "$root/.github/tests/go-valid-fixture"
GITHUB_SHA="$(git rev-parse HEAD)"
GO_DISK_WORKFLOW_SHA="$GITHUB_SHA"
export GITHUB_SHA GO_DISK_WORKFLOW_SHA
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test ImageOS=ubuntu26 ImageVersion=20261025.179.1
export GITHUB_REPOSITORY=devantler-tech/fixture GITHUB_WORKSPACE="$root"
export GO_DISK_WORKFLOW_REPOSITORY=devantler-tech/.github
export GO_DISK_OBSERVATION=true
mkdir -p "$scratch/bin" "$scratch/module" "$scratch/build" "$scratch/toolchain" "$scratch/tmp" "$scratch/runner"
export RUNNER_TEMP="$scratch/runner" OBS_TEST_ROOT="$scratch"
cat >"$scratch/bin/go" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == env && "$2" == -json && "$#" -gt 2 ]] || exit 91
if [[ "${OBS_TEST_MODE:-}" == go-hung ]]; then
  trap '' TERM
  echo "$BASHPID" >"$OBS_TEST_ROOT/hung-pid"
  sleep 30
fi
keys="$(printf '%s\n' "${@:3}" | jq -Rnc '[inputs]')"
jq -nc --arg root "$OBS_TEST_ROOT" --argjson keys "$keys" '{GOCACHE:($root+"/build"),GOMODCACHE:($root+"/module"),GOROOT:($root+"/toolchain"),GOTMPDIR:($root+"/tmp"),GOVERSION:"go1.27.3",GOOS:"linux",GOARCH:"amd64",CGO_ENABLED:"1"} |
  with_entries(select(.key as $key | $keys | index($key)))'
SH
cat >"$scratch/probe-delay.sh" <<'SH'
delay_probe() {
  local count=0
  case "${OBS_TEST_MODE:-}:$1" in
    slow-edge:*)
      [[ ! -f "$OBS_TEST_ROOT/probe-count" ]] || count="$(cat "$OBS_TEST_ROOT/probe-count")"
      count=$((count + 1))
      printf '%s\n' "$count" >"$OBS_TEST_ROOT/probe-count"
      # Initial df plus 8*(2 df + 2 stat attempts) + 7 du = 40 probes.
      if ((count <= 40)); then sleep 0.9; fi
      ;;
    slow-stop:du)
      if [[ -f "$OBS_TEST_ROOT/command-running" ]]; then
        [[ ! -f "$OBS_TEST_ROOT/probe-count" ]] || count="$(cat "$OBS_TEST_ROOT/probe-count")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$OBS_TEST_ROOT/probe-count"
        if ((count <= 7)); then
          : >"$OBS_TEST_ROOT/slow-frame-started"
          sleep 1.7
        fi
      fi
      ;;
  esac
}
SH
cat >"$scratch/bin/df" <<'SH'
#!/usr/bin/env bash
source "$OBS_TEST_ROOT/probe-delay.sh"
delay_probe df
printf 'Filesystem blocks Used Available Capacity Mounted\nfixture 10000 2000 8000 20%% /\n'
[[ "${OBS_TEST_MODE:-}" != partial ]] || exit 23
SH
cat >"$scratch/bin/stat" <<'SH'
#!/usr/bin/env bash
source "$OBS_TEST_ROOT/probe-delay.sh"
delay_probe stat
# Exercise the legitimate GNU-to-BSD fallback instead of counting one stat only.
if [[ "${OBS_TEST_MODE:-}" == slow-edge && "$*" == *' -c '* ]]; then exit 23; fi
case "${*: -1}" in */module|*/build) echo 9 ;; *) echo 1 ;; esac
SH
cat >"$scratch/bin/du" <<'SH'
#!/usr/bin/env bash
source "$OBS_TEST_ROOT/probe-delay.sh"
delay_probe du
printf '42\tprivate-path\n'
[[ "${OBS_TEST_MODE:-}" != du-partial ]] || exit 23
SH
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"
export GO_DISK_MODULE_PRIMARY_KEY=go-mod-fixture GO_DISK_MODULE_MATCHED_KEY=go-mod-fixture GO_DISK_MODULE_CACHE_HIT=true
export GO_DISK_BUILD_PRIMARY_KEY=go-build-fixture GO_DISK_BUILD_MATCHED_KEY=go-build-fixture GO_DISK_BUILD_CACHE_HIT=true
# The real keyed Go query returns only named fields. Otherwise dropping a
# required key from the production query could still pass every fixture.
go env -json GOCACHE | jq -e 'keys==["GOCACHE"]' >/dev/null || fail 'keyed Go shim returned unrequested metadata'
sed 's/GOTMPDIR GOVERSION GOOS/GOTMPDIR GOOS/' "$script" >"$scratch/no-goversion.sh"
! cmp -s "$script" "$scratch/no-goversion.sh" || fail 'GOVERSION query ablation changed nothing'
bash "$scratch/no-goversion.sh" snapshot after-setup >"$scratch/output" 2>"$scratch/error"
[[ ! -e "$RUNNER_TEMP/go-disk-observation/identity.json" ]] || fail 'missing GOVERSION query was not detected'
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
# The two controls use successful probes below the individual two-second limit.
# Seven 1.7s walks exceed the old 10s stop wait; forty 0.9s probes exceed the
# old 30s edge wait. Only one frame is slowed, keeping this regression bounded.
budget_failures=0
for scenario in slow-stop slow-edge; do
  rm -rf -- "$RUNNER_TEMP/go-disk-observation"
  rm -f "$scratch/probe-count" "$scratch/command-running" "$scratch/slow-frame-started"
  {
    bash "$script" snapshot after-setup
    bash "$script" snapshot after-restore
  } >>"$scratch/output" 2>>"$scratch/error"
  rc=0
  if [[ "$scenario" == slow-stop ]]; then
    OBS_TEST_MODE="$scenario" bash "$script" test bash -c '
      : >"$OBS_TEST_ROOT/command-running"
      for _ in {1..100}; do
        [[ ! -f "$OBS_TEST_ROOT/slow-frame-started" ]] || exit 7
        sleep 0.1
      done
      exit 99' >>"$scratch/output" 2>>"$scratch/error" || rc=$?
  else
    OBS_TEST_MODE="$scenario" bash "$script" test bash -c 'sleep 4; exit 7' >>"$scratch/output" 2>>"$scratch/error" || rc=$?
  fi
  [[ "$rc" == 7 ]] || fail "$scenario changed the original command result"
  if ! jq -e '.complete and .command.exit==7 and .command.observerCompleted' "$RUNNER_TEMP/go-disk-observation/public/report.json" >/dev/null; then
    printf 'Successful %s frame exceeded the observer budget\n' "$scenario" >&2
    budget_failures=$((budget_failures + 1))
  fi
done
[[ "$budget_failures" == 0 ]] || fail 'successful bounded observation frames were truncated'
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
rm -f "$scratch/probe-count" "$scratch/command-running" "$scratch/slow-frame-started"
printf 'Go disk observation keyed-query and frame-budget controls passed\n'
# Cancellation keeps its original short process-group cleanup rather than
# waiting for the larger cooperative completion budget of a valid frame.
{
  bash "$script" snapshot after-setup
  bash "$script" snapshot after-restore
} >>"$scratch/output" 2>>"$scratch/error"
OBS_TEST_MODE=slow-stop bash "$script" test bash -c '
  echo "$BASHPID" >"$OBS_TEST_ROOT/command-pid"
  : >"$OBS_TEST_ROOT/command-running"
  sleep 20' >>"$scratch/output" 2>>"$scratch/error" &
collector=$!
for _ in {1..100}; do
  [[ ! -f "$scratch/slow-frame-started" ]] || break
  sleep 0.1
done
[[ -f "$scratch/slow-frame-started" ]] || fail 'rich cancellation never reached its slow frame'
cancel_started=$SECONDS
kill -TERM "$collector"
rc=0
wait "$collector" || rc=$?
[[ "$rc" == 143 ]] || fail 'rich cancellation changed the original signal result'
((SECONDS - cancel_started <= 6)) || fail 'rich cancellation waited for the cooperative frame budget'
! kill -0 "$(cat "$scratch/command-pid")" 2>/dev/null || fail 'rich cancellation left its command alive'
count="$(cat "$scratch/probe-count")"
sleep 3
[[ "$(cat "$scratch/probe-count")" == "$count" ]] || fail 'rich sampler survived cancellation'
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
rm -f "$scratch/probe-count" "$scratch/command-running" "$scratch/slow-frame-started" "$scratch/command-pid"
# An immediate command can finish before the first periodic tick. Its Go result
# and clean observer shutdown do not replace missing during-command coverage.
{
  bash "$script" snapshot after-setup
  bash "$script" snapshot after-restore
  bash "$script" test true
} >>"$scratch/output" 2>>"$scratch/error"
jq -e '.complete==false and .command.completed and .command.exit==0 and .command.observerCompleted and
  all(.frames[];.phase!="during-command")' "$RUNNER_TEMP/go-disk-observation/public/report.json" >/dev/null || fail 'short command invented during-command coverage'
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
# Removing path collection or switching the workload cache must lose this evidence.
bash "$script" snapshot after-setup >"$scratch/output" 2>"$scratch/error" || fail 'after-setup observation is unsupported'
bash "$script" snapshot after-restore >>"$scratch/output" 2>>"$scratch/error"
rc=0
bash "$script" test bash -c 'sleep 4; exit 23' >>"$scratch/output" 2>>"$scratch/error" || rc=$?
[[ "$rc" == 23 ]] || fail 'observation replaced the failed command result'
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
report="$RUNNER_TEMP/go-disk-observation/public/report.json"
jq -e '.complete and .command.executed and .command.exit == 23 and .quotaLimits == "not-established" and
  .cacheArchiveIdentity == "not-established" and .toolchain.version == "go1.27.3" and
  .caches.module.primary == "go-mod-fixture" and .caches.module.matched == "go-mod-fixture" and .caches.module.hit == true and
  ([.frames[].phase] | index("after-setup") != null and index("after-restore") != null and index("before-command") != null and index("during-command") != null and index("command-exit") != null) and
  all(.frames[]; (.entries|length)==8) and any(.frames[].entries[];.componentStatus=="not-collected") and
  any(.frames[-1].entries[]; .label=="build-cache" and .totalInodes==10000 and .componentKiB==42) and
  ([.frames[-1].entries[]|select(.label=="build-cache" or .label=="module-cache")|.filesystemGroup]|unique|length)==1 and
  ([.frames[-1].entries[]|.filesystemGroup]|unique|length)==2' "$report" >/dev/null || fail 'actual per-path, inode, phase or provenance evidence was lost'
! grep -F "$scratch" "$report" "$scratch/output" >/dev/null || fail 'private paths escaped into public evidence'
# Keeping all frames in a shell argument loses longer, otherwise bounded runs.
jq -cn --slurpfile frames "$RUNNER_TEMP/go-disk-observation/frames.jsonl" \
  'range(0;700) as $n | $frames[-1] | .phase="during-command" | .epoch += $n' >"$scratch/history"
cat "$scratch/history" >>"$RUNNER_TEMP/go-disk-observation/frames.jsonl"
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
jq -e '.complete and (.frames|length)>700' "$report" >/dev/null || fail 'bounded observation history was lost'
! grep -F "$scratch" "$scratch/error" >/dev/null || fail 'observer failure disclosed a private path'
# A failed append after an earlier complete publication must revoke that verdict.
mv "$RUNNER_TEMP/go-disk-observation/frames.jsonl" "$scratch/frames"
mkdir "$RUNNER_TEMP/go-disk-observation/frames.jsonl"
bash "$script" snapshot after-restore >>"$scratch/output" 2>>"$scratch/error"
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
! grep -F "$scratch" "$scratch/error" >/dev/null || fail 'failed observation append disclosed a private path'
jq -e '.complete==false' "$report" >/dev/null || fail 'failed append left a stale complete observation'
printf 'Go disk observation component controls passed\n'
# A size-walk failure must retain the independent filesystem evidence needed
# at command failure time, while disqualifying the observation as complete.
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
{
  OBS_TEST_MODE=du-partial bash "$script" snapshot after-setup
  OBS_TEST_MODE=du-partial bash "$script" snapshot after-restore
} >>"$scratch/output" 2>>"$scratch/error"
rc=0
OBS_TEST_MODE=du-partial bash "$script" test bash -c 'sleep 2; exit 7' >>"$scratch/output" 2>>"$scratch/error" || rc=$?
[[ "$rc" == 7 ]] || fail 'failed component walk changed Go failure'
jq -e '.complete==false and .command.exit==7 and
  any(.frames[];.phase=="during-command") and
  any(.frames[-1].entries[];.label=="build-cache" and .availableKiB==8000 and .componentStatus=="unknown" and .componentKiB==null)' \
  "$report" >/dev/null || fail 'failed component walk discarded independent filesystem evidence'
# A cold cache is described through its parent filesystem; observation must
# never manufacture a cache directory or substitute a workload cache.
rm -rf -- "$RUNNER_TEMP/go-disk-observation" "$scratch/module" "$scratch/build"
bash "$script" snapshot after-setup >>"$scratch/output" 2>>"$scratch/error"
[[ ! -e "$scratch/module" && ! -e "$scratch/build" ]] || fail 'cold observation created workload caches'
jq -se 'any(.[].entries[];.label=="module-cache" and .status=="absent" and .filesystemScope=="nearest-existing-parent" and .componentKiB==0)' \
  "$RUNNER_TEMP/go-disk-observation/frames.jsonl" >/dev/null || fail 'cold cache absence was not distinguished from measured contents'
{
  GO_DISK_MODULE_CACHE_HIT=false GO_DISK_MODULE_MATCHED_KEY='' GO_DISK_BUILD_CACHE_HIT=false GO_DISK_BUILD_MATCHED_KEY='' bash "$script" snapshot after-restore
  bash "$script" test bash -c 'sleep 2'
} >>"$scratch/output" 2>>"$scratch/error"
jq -e '.complete and any(.frames[-1].entries[];.label=="module-cache" and .componentStatus=="absent")' "$report" >/dev/null || fail 'legitimate absent paths disqualified complete observation'
[[ ! -e "$scratch/module" && ! -e "$scratch/build" ]] || fail 'cold command observation created workload caches'
mkdir "$scratch/module" "$scratch/build"
# Full-looking stdout followed by an error is not a successful probe. The Go
# command still runs exactly once and keeps both successful and failed results.
for result in 0 7; do
  rm -rf -- "$RUNNER_TEMP/go-disk-observation"
  OBS_TEST_MODE=partial bash "$script" snapshot after-setup >>"$scratch/output" 2>>"$scratch/error"
  OBS_TEST_MODE=partial bash "$script" snapshot after-restore >>"$scratch/output" 2>>"$scratch/error"
  : >"$scratch/command-count"
  rc=0
  OBS_TEST_MODE=partial bash "$script" test bash -c 'echo once >>"$1"; exit "$2"' bash "$scratch/command-count" "$result" >>"$scratch/output" 2>>"$scratch/error" || rc=$?
  [[ "$rc" == "$result" && "$(wc -l <"$scratch/command-count")" -eq 1 ]] || fail 'failed probe replaced or repeated Go command'
  jq -e '.complete==false' "$report" >/dev/null || fail 'partial probe produced a complete observation'
done
# Keyed toolchain queries are also observers and must be bounded. An unbounded
# `go env` can otherwise prevent the real command from ever starting.
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
timeout_command=timeout
if command -v gnutimeout >/dev/null 2>&1; then timeout_command=gnutimeout; fi
if command -v gtimeout >/dev/null 2>&1; then timeout_command=gtimeout; fi
rc=0
OBS_TEST_MODE=go-hung "$timeout_command" --kill-after=1s 7s bash "$script" snapshot after-setup >>"$scratch/output" 2>>"$scratch/error" || rc=$?
[[ "$rc" == 0 ]] || fail 'hung keyed Go query prevented ordinary command admission'
jq -e '.complete==false' "$report" >/dev/null || fail 'hung Go query produced a complete observation'
if [[ -f "$scratch/hung-pid" ]]; then
  ! kill -0 "$(cat "$scratch/hung-pid")" 2>/dev/null || fail 'bounded query left an owned probe alive'
fi
printf 'Go disk observation cold/failed probe controls passed\n'
# A slow but successful multi-component frame must not inherit the old single-df
# edge budget. All reads remain individually bounded.
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
cat >"$scratch/bin/du" <<'SH'
#!/usr/bin/env bash
sleep 0.4
printf '42\tprivate-path\n'
SH
{
  bash "$script" snapshot after-setup
  bash "$script" snapshot after-restore
  bash "$script" test bash -c 'sleep 4'
} >>"$scratch/output" 2>>"$scratch/error"
jq -e '.complete' "$report" >/dev/null || fail 'successful bounded component walks were truncated by the single-df budget'
printf 'Go disk observation bounded component controls passed\n'
: >"$scratch/command-count"
bash "$script" test bash -c 'echo once >>"$1"' bash "$scratch/command-count" >>"$scratch/output" 2>>"$scratch/error"
[[ "$(wc -l <"$scratch/command-count")" -eq 1 ]] || fail 'reused state repeated the ordinary command'
jq -e '.complete==false' "$report" >/dev/null || fail 'reused command state was reported as one complete observation'
cat >"$scratch/bin/du" <<'SH'
#!/usr/bin/env bash
printf '42\tprivate-path\n'
SH
# Unexpected death never acknowledges the parent's cooperative stop intent.
for signal in TERM KILL; do
  rm -rf -- "$RUNNER_TEMP/go-disk-observation"
  {
    bash "$script" snapshot after-setup
    bash "$script" snapshot after-restore
  } >>"$scratch/output" 2>>"$scratch/error"
  rm -f "$scratch/command-pid"
  bash "$script" test bash -c 'echo "$BASHPID" >"$1"; sleep 4; exit 7' bash "$scratch/command-pid" >>"$scratch/output" 2>>"$scratch/error" &
  collector=$!
  for _ in {1..100}; do
    [[ -s "$scratch/command-pid" ]] && break
    sleep 0.05
  done
  [[ -s "$scratch/command-pid" ]] || fail 'owned command did not start'
  command_pid="$(cat "$scratch/command-pid")"
  sampler=''
  children="$(pgrep -P "$collector")" || fail 'owned sampler was not running'
  for child in $children; do [[ "$child" == "$command_pid" ]] || sampler="$child"; done
  [[ -n "$sampler" ]] || fail 'owned sampler identity was unavailable'
  kill -"$signal" "$sampler"
  rc=0
  wait "$collector" || rc=$?
  [[ "$rc" == 7 ]] || fail 'sampler death replaced Go failure'
  jq -e '.complete==false' "$report" >/dev/null || fail 'unexpected sampler death reported complete'
done
# Private state links must not redirect observer writes or become artifact input.
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
bash "$script" snapshot after-setup >>"$scratch/output" 2>>"$scratch/error"
printf 'untouched\n' >"$scratch/private-target"
rm "$RUNNER_TEMP/go-disk-observation/frames.jsonl"
ln -s "$scratch/private-target" "$RUNNER_TEMP/go-disk-observation/frames.jsonl"
bash "$script" snapshot after-restore >>"$scratch/output" 2>>"$scratch/error"
[[ "$(cat "$scratch/private-target")" == untouched ]] || fail 'observer followed private state link'
jq -e '.complete==false' "$report" >/dev/null || fail 'linked state reported complete'
printf 'Go disk observation reuse/death/state controls passed\n'
# A plausible final JSON producer that exits nonzero must not commit its output.
real_jq="$(command -v jq)"
export OBS_REAL_JQ="$real_jq"
cat >"$scratch/bin/jq" <<'SH'
#!/usr/bin/env bash
"$OBS_REAL_JQ" "$@"
result=$?
case "${OBS_JQ_FAILURE_MODE:-report}:$*" in
  report:*'--argjson identity'*|completion:*'--argjson observerCompleted'*) exit 23 ;;
esac
exit "$result"
SH
chmod +x "$scratch/bin/jq"
for fault in report completion; do
  for result in 0 7; do
    rm -rf -- "$RUNNER_TEMP/go-disk-observation"
    {
      bash "$script" snapshot after-setup
      bash "$script" snapshot after-restore
    } >>"$scratch/output" 2>>"$scratch/error"
    rc=0
    OBS_JQ_FAILURE_MODE="$fault" bash "$script" test bash -c 'exit "$1"' bash "$result" >>"$scratch/output" 2>>"$scratch/error" || rc=$?
    [[ "$rc" == "$result" ]] || fail 'failed final producer replaced Go result'
    "$real_jq" -e '.complete==false' "$report" >/dev/null || fail 'failed final producer published complete output'
    # jq owns $rc; the command exit is deliberately passed as structured data.
    # shellcheck disable=SC2016
    "$real_jq" -e --argjson rc "$result" '.exit==$rc and .completed and (.finishedEpoch|type=="number")' \
      "$RUNNER_TEMP/go-disk-observation/command.json" >/dev/null || fail 'Go result was lost before observer finalization'
    if [[ "$fault" == completion ]]; then
      "$real_jq" -e '.observerCompleted==false' "$RUNNER_TEMP/go-disk-observation/command.json" >/dev/null || fail 'failed completion producer committed its successful-looking output'
      OBS_JQ_FAILURE_MODE=none bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
      "$real_jq" -e '.complete==false and .command.observerCompleted==false' "$report" >/dev/null || fail 'separate publisher forgot incomplete collection'
    fi
  done
done
rm "$scratch/bin/jq"
# The collection limit is adverse evidence, never a successful truncated history.
head -c 8388609 /dev/zero >"$RUNNER_TEMP/go-disk-observation/frames.jsonl"
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
jq -e '.complete==false' "$report" >/dev/null || fail 'oversized history reported complete'
! grep -F "$scratch" "$scratch/output" "$scratch/error" "$report" >/dev/null || fail 'failure diagnostics disclosed private paths'
printf 'Go disk observation final-write/limit controls passed\n'
# Missing runner identity does not invalidate useful counters, but it cannot
# establish complete source/runner provenance.
completeness_failures=0
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
{
  env -u ImageOS -u ImageVersion bash "$script" snapshot after-setup
  env -u ImageOS -u ImageVersion bash "$script" snapshot after-restore
  env -u ImageOS -u ImageVersion bash "$script" test bash -c 'sleep 2'
  env -u ImageOS -u ImageVersion bash "$script" publish
} >>"$scratch/output" 2>>"$scratch/error"
if ! jq -e '.complete==false and .image=="unknown" and .imageVersion=="unknown" and (.frames|length)>0' "$report" >/dev/null; then
  printf 'Missing image identity was reported complete\n' >&2
  completeness_failures=$((completeness_failures + 1))
fi
# Fail the real marker-writing boundary as well as a full-looking du producer.
# A later publisher must derive incompleteness from retained component evidence,
# rather than depend on that marker being durably writable.
real_touch="$(command -v touch)"
export OBS_REAL_TOUCH="$real_touch"
cat >"$scratch/bin/touch" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in */go-disk-observation/incomplete) exit 23 ;; esac
exec "$OBS_REAL_TOUCH" "$@"
SH
chmod +x "$scratch/bin/touch"
cat >"$scratch/bin/du" <<'SH'
#!/usr/bin/env bash
printf '42\tprivate-path\n'
exit 23
SH
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
{
  OBS_TEST_MODE=du-partial bash "$script" snapshot after-setup
  OBS_TEST_MODE=du-partial bash "$script" snapshot after-restore
  OBS_TEST_MODE=du-partial bash "$script" test bash -c 'sleep 2'
} >>"$scratch/output" 2>>"$scratch/error"
[[ ! -e "$RUNNER_TEMP/go-disk-observation/incomplete" ]] || fail 'marker-write fault did not exercise the real boundary'
jq -e 'any(.frames[].entries[];.componentStatus=="unknown" and .availableKiB==8000)' "$report" >/dev/null || fail 'component producer fault did not retain real failed-walk evidence'
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
if ! jq -e '.complete==false and .command.exit==0 and
  any(.frames[].entries[];.componentStatus=="unknown" and .availableKiB==8000)' "$report" >/dev/null; then
  printf 'Lost failure marker allowed unknown component evidence to become complete\n' >&2
  completeness_failures=$((completeness_failures + 1))
fi
# A killed sampler may leave only valid frames. With the same marker fault,
# a separate publisher must still retain the main invocation's failed verdict.
cat >"$scratch/bin/du" <<'SH'
#!/usr/bin/env bash
printf '42\tprivate-path\n'
SH
rm -rf -- "$RUNNER_TEMP/go-disk-observation"
{
  bash "$script" snapshot after-setup
  bash "$script" snapshot after-restore
} >>"$scratch/output" 2>>"$scratch/error"
rm -f "$scratch/command-pid"
bash "$script" test bash -c 'echo "$BASHPID" >"$1"; sleep 12' bash "$scratch/command-pid" >>"$scratch/output" 2>>"$scratch/error" &
collector=$!
for _ in {1..100}; do
  [[ -s "$scratch/command-pid" ]] && jq -e -s 'any(.[];.phase=="during-command")' "$RUNNER_TEMP/go-disk-observation/frames.jsonl" >/dev/null 2>&1 && break
  sleep 0.1
done
jq -e -s 'any(.[];.phase=="during-command")' "$RUNNER_TEMP/go-disk-observation/frames.jsonl" >/dev/null || fail 'sampler-loss control never retained a valid periodic frame'
command_pid="$(cat "$scratch/command-pid")"
sampler=''
children="$(pgrep -P "$collector")" || fail 'sampler-loss control lost its owned children'
for child in $children; do [[ "$child" == "$command_pid" ]] || sampler="$child"; done
[[ -n "$sampler" ]] || fail 'sampler-loss control has no owned sampler'
kill -KILL "$sampler"
rc=0
wait "$collector" || rc=$?
[[ "$rc" == 0 && ! -e "$RUNNER_TEMP/go-disk-observation/incomplete" ]] || fail 'sampler-loss control changed Go result or retained its failed marker'
jq -e '.complete==false and .command.completed and .command.exit==0 and .command.observerCompleted==false and
  all(.frames[].entries[];.componentStatus!="unknown") and
  any(.frames[];.phase=="command-exit")' "$report" >/dev/null || fail 'sampler-loss control did not isolate otherwise valid retained observations'
bash "$script" publish >>"$scratch/output" 2>>"$scratch/error"
if ! jq -e '.complete==false and .command.completed and .command.exit==0 and .command.observerCompleted==false' "$report" >/dev/null; then
  printf 'Lost failure marker allowed a dead sampler to become complete\n' >&2
  completeness_failures=$((completeness_failures + 1))
fi
rm "$scratch/bin/touch"
[[ "$completeness_failures" == 0 ]] || fail 'runner/component completeness controls failed'
printf 'Go disk observation provenance/marker-loss controls passed\n'
