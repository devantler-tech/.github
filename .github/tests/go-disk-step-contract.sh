#!/usr/bin/env bash
# Execute production commands in both states, preserving Go and cleanup results.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "::error::$*" >&2; exit 1; }
mkdir "$scratch/bin"
cp "$root/.github/scripts/measure-go-disk.sh" "$scratch/measure-go-disk.sh"
cat > "$scratch/bin/go" <<'GO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISK_COMMAND_ARGS"
exit "${GO_FIXTURE_EXIT:-0}"
GO
cat > "$scratch/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$DISK_CLEANUP_ARGS"
[[ "${CLEANUP_FIXTURE_EXIT:-0}" == 0 ]] || exit "$CLEANUP_FIXTURE_EXIT"
touch "$DISK_CLEANUP_FINISHED"
SUDO
# These are the only external boundaries: no real privileged deletion is allowed.
cat > "$scratch/bin/df" <<'DF'
#!/usr/bin/env bash
case "$*" in
  '-Pk .')
    available=8000; used=2000
    if [[ -e "$DISK_CLEANUP_FINISHED" ]]; then available=9000; used=1000; fi
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 10000 %s %s 20%% /\n' "$used" "$available"
    ;;
  '--output=avail -BG /')
    [[ "${CLEANUP_DF_EXIT:-0}" == 0 ]] || exit "$CLEANUP_DF_EXIT"
    available=8
    [[ ! -e "$DISK_CLEANUP_FINISHED" ]] || available=9
    printf 'Avail\n%sG\n' "$available"
    ;;
  *) exit 2 ;;
esac
DF
chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH" DISK_COMMAND_ARGS="$scratch/args" RUNNER_TEMP="$scratch"
export DISK_CLEANUP_ARGS="$scratch/cleanup-args" DISK_CLEANUP_FINISHED="$scratch/cleaned"
export GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 GITHUB_SHA=consumer-head GO_DISK_WORKFLOW_SHA=workflow-source
for job in build test coverage; do
  JOB_ID="$job" yq -o=json '.jobs[strenv(JOB_ID)].steps' "$workflow" | jq -e '
    [to_entries[] | select(.value.name == "Reserve disk measurement checkout path")] as $guard |
    [to_entries[] | select(.value.name == "Checkout disk measurement helper")] as $checkout |
    [to_entries[] | select(.value.name == "Prepare disk measurement outside the consumer workspace")] as $prepare |
    [to_entries[] | select(.value.name == "🧹 Free disk space")] as $cleanup |
    ($guard|length) == 1 and ($checkout|length) == 1 and ($prepare|length) == 1 and ($cleanup|length) == 1 and
    $guard[0].key < $checkout[0].key and $checkout[0].key < $prepare[0].key and $prepare[0].key < $cleanup[0].key and
    $guard[0].value.if == "${{ inputs.measure-disk-usage == true }}" and
    $checkout[0].value.if == $guard[0].value.if and $prepare[0].value.if == $guard[0].value.if and
    $cleanup[0].value.env.MEASURE_DISK_USAGE == "${{ inputs.measure-disk-usage }}" and
    $cleanup[0].value.env.GO_DISK_WORKFLOW_SHA == "${{ job.workflow_sha }}"
  ' >/dev/null || fail "$job must install its opt-in observer before cleanup with bound identities"
done
for enabled in false true; do
  : > "$scratch/args"
  for job in build test coverage; do
    yq -r ".jobs.$job.steps[] | select(.name == \"🛠️ Build\" or .name == \"🧪 Test\" or .name == \"📄 Generate coverage\") | .run" "$workflow" > "$scratch/step"
    [[ -s "$scratch/step" ]] || fail "Missing $job command"
    MEASURE_DISK_USAGE="$enabled" bash -euo pipefail "$scratch/step" > /dev/null
    rc=0
    MEASURE_DISK_USAGE="$enabled" GO_FIXTURE_EXIT=19 bash -euo pipefail "$scratch/step" > /dev/null || rc=$?
    [[ "$rc" == 19 ]] || fail "$job $enabled concealed the Go failure"
    yq -r ".jobs.$job.steps[] | select(.name == \"🧹 Free disk space\") | .run" "$workflow" > "$scratch/cleanup-step"
    for outcome in reclaimed deletion-failed read-failed; do
      rm -f "$scratch/cleaned"
      : > "$scratch/cleanup-args"
      cleanup_exit=0; df_exit=0; want=0
      [[ "$outcome" != deletion-failed ]] || cleanup_exit=17
      [[ "$outcome" != read-failed ]] || { df_exit=31; want=31; }
      rc=0
      MEASURE_DISK_USAGE="$enabled" CLEANUP_FIXTURE_EXIT="$cleanup_exit" CLEANUP_DF_EXIT="$df_exit" bash -euo pipefail "$scratch/cleanup-step" > "$scratch/cleanup-result" || rc=$?
      [[ "$rc" == "$want" ]] || fail "$job $enabled $outcome changed cleanup exit $want to $rc"
      if [[ "$outcome" == read-failed ]]; then
        [[ ! -s "$scratch/cleanup-args" ]] || fail 'failed initial capacity read still admitted deletion'
      else
        diff -u <(printf '%s\n' rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/share/boost /usr/share/swift /opt/hostedtoolcache/CodeQL /opt/hostedtoolcache/PyPy /usr/local/share/powershell /usr/share/miniconda) "$scratch/cleanup-args" || fail "$job $enabled changed cleanup targets"
      fi
      sed -n 's/^GO_DISK_USAGE //p' "$scratch/cleanup-result" > "$scratch/receipt"
      if [[ "$enabled" == false ]]; then
        [[ ! -s "$scratch/receipt" ]] || fail 'disabled cleanup unexpectedly sampled disk'
      else
        final=8000
        [[ "$outcome" != reclaimed ]] || final=9000
        jq -se --arg phase "cleanup-$job" --argjson final "$final" --argjson rc "$want" '
          length == 1 and .[0].status == "measured" and .[0].phase == $phase and
          .[0].initial_available_kib == 8000 and .[0].final_available_kib == $final and
          .[0].command_exit == $rc and .[0].run_id == "123" and .[0].attempt == "2" and
          .[0].head == "consumer-head" and .[0].workflow_sha == "workflow-source"
        ' "$scratch/receipt" >/dev/null || fail "$job $outcome lacks complete attributable pre/post cleanup observations"
      fi
    done
  done
  diff -u <(printf '%s\n' 'build -v ./...' 'build -v ./...' 'test ./...' 'test ./...' 'test -race -coverprofile=coverage.txt -covermode=atomic ./...' 'test -race -coverprofile=coverage.txt -covermode=atomic ./...') "$scratch/args"
done
