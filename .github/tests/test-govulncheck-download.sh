#!/usr/bin/env bash
# The scanner action downloads its module dependencies before the scan, through
# the shared bounded retry, so a module-proxy blip is retried instead of failing
# as a scan. Pin that wiring, then drive the real script and the real retry
# helper; only the `go` process is a fixture.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-$root/.github/actions/govulncheck/action.yaml}"
fail() { echo "FAIL: $*" >&2; exit 1; }

wiring='
  .runs.steps as $steps |
  ($steps | map(.id // .name)) as $order |
  ($steps | map(select((.run // "") | contains("download.sh")))) as $download |
  ($steps | map(select(.id == "scan"))) as $scan |
  ($download | length == 1) and ($scan | length == 1) and
  ($order | index("go-mod-cache")) < ($order | index($download[0].name)) and
  ($order | index($download[0].name)) < ($order | index("scan")) and
  $download[0].run == "bash \"$ACTION_PATH/download.sh\" \"$WORK_DIR\" \"$ACTION_PATH/../../../.scripts/retry.sh\"" and
  $download[0].env.ACTION_PATH == "${{ github.action_path }}" and
  $download[0].env.WORK_DIR == "${{ inputs.work-dir }}" and
  $download[0].env.RETRY_MAX_ATTEMPTS == "3" and
  $download[0].env.RETRY_BASE_DELAY == "5" and
  $download[0].env.GOTOOLCHAIN == $scan[0].env.GOTOOLCHAIN and
  ($download[0]["continue-on-error"] // false) == false and
  ($download[0].if // null) == null and
  ($scan[0].run | contains("retry") | not)
'
yq -o=json . "$action" | jq -e "$wiring" >/dev/null ||
  fail 'the scan must follow one unconditional, 3-attempt retried module download'
[[ -f "$(dirname "$action")/../../../.scripts/retry.sh" ]] || fail 'the shared retry helper must resolve from the action'
echo 'PASS: the module download is retried 3 times before a scan that runs once'

if (($# > 0)); then exit 0; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
blocks() {
  local label="$1" mutation="$2" out
  cp "$action" "$work/action.yaml"
  yq -i "$mutation" "$work/action.yaml"
  if out="$(bash "$0" "$work/action.yaml" 2>&1)"; then
    fail "$label: accepted broken wiring"
  fi
  [[ "$out" == *'3-attempt retried module download'* ]] || fail "$label: wrong refusal: $out"
  echo "PASS: rejects $label"
}
blocks 'a missing download' 'del(.runs.steps[] | select((.run // "") | contains("download.sh")))'
blocks 'a download after the scan' \
  '.runs.steps = ([.runs.steps[] | select((.run // "") | contains("download.sh") | not)] + [.runs.steps[] | select((.run // "") | contains("download.sh"))])'
blocks 'a download before the cache restore' \
  '.runs.steps = ([.runs.steps[] | select((.run // "") | contains("download.sh"))] + [.runs.steps[] | select((.run // "") | contains("download.sh") | not)])'
blocks 'an unbounded attempt count' '(.runs.steps[] | select((.run // "") | contains("download.sh")) | .env) |= del(.RETRY_MAX_ATTEMPTS)'
blocks 'more attempts' '(.runs.steps[] | select((.run // "") | contains("download.sh")) | .env.RETRY_MAX_ATTEMPTS) = "5"'
blocks 'a download that cannot fail the job' '(.runs.steps[] | select((.run // "") | contains("download.sh")) | .["continue-on-error"]) = true'
blocks 'a skippable download' '(.runs.steps[] | select((.run // "") | contains("download.sh")) | .if) = "false"'
blocks 'a different Go toolchain from the scan' '(.runs.steps[] | select((.run // "") | contains("download.sh")) | .env.GOTOOLCHAIN) = "auto"'
blocks 'a retried scan' '(.runs.steps[] | select(.id == "scan") | .run) = "bash \"$ACTION_PATH/../../../.scripts/retry.sh\" bash \"$ACTION_PATH/scan.sh\""'

# Drive the real download script and retry helper. The fixture `go` fails the
# first FAILURES calls the way the proxy does, then succeeds.
script="$root/.github/actions/govulncheck/download.sh"
retry="$root/.scripts/retry.sh"
attempts="$(yq -r '.runs.steps[] | select((.run // "") | contains("download.sh")) | .env.RETRY_MAX_ATTEMPTS' "$action")"
mkdir -p "$work/bin" "$work/module with spaces"
cat >"$work/bin/go" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'env GOWORK' ]]; then
  printf '%s\n' "$STUB_GOWORK"
  exit 0
fi
printf '%s|%s\n' "$PWD" "$*" >>"$CALLS"
calls="$(wc -l <"$CALLS")"
if ((calls <= FAILURES)); then
  echo 'stream error: stream ID 1; INTERNAL_ERROR; received from peer' >&2
  exit 1
fi
SH
chmod +x "$work/bin/go"
export PATH="$work/bin:$PATH" CALLS="$work/calls" RETRY_MAX_ATTEMPTS="$attempts" RETRY_BASE_DELAY=0 STUB_GOWORK=''
module="$work/module with spaces"
run() { # run <label> <failures> <want-exit> <want-calls> <expected-output>
  local label="$1" rc=0 out calls=0
  : >"$CALLS"
  out="$(cd "$work" && FAILURES="$2" bash "$script" "module with spaces" "$retry" 2>&1)" || rc=$?
  [[ -s "$CALLS" ]] && calls="$(wc -l <"$CALLS")"
  if [[ "$rc" != "$3" ]] || ((calls != $4)) || [[ "$out" != *"$5"* ]]; then
    printf 'FAIL: %s: wanted exit %s after %s calls with %s; got exit %s after %s calls\n%s\n' \
      "$label" "$3" "$4" "$5" "$rc" "$calls" "$out" >&2
    exit 1
  fi
  if ((calls > 0)) && grep -vqxF "$module|mod download" "$CALLS"; then
    fail "$label: download ran outside the module or with other arguments: $(cat "$CALLS")"
  fi
  echo "PASS: $label"
}
run 'a reachable proxy downloads once' 0 0 1 'Downloaded the module dependencies'
run 'a transient proxy error is retried' 2 0 3 'Downloaded the module dependencies'
run 'an unreachable proxy fails naming the download' 3 1 3 'not a vulnerability finding: the scan did not run'
mkdir -p "$module/vendor"
: >"$module/vendor/modules.txt"
run 'a vendored module needs no download' 3 0 0 'needs no download'
STUB_GOWORK=off run 'a vendored module with workspaces off needs no download' 3 0 0 'needs no download'
# In workspace mode Go reads only the workspace's vendor directory, never the module's.
STUB_GOWORK="$work/go.work" run 'a workspace ignores the module vendor directory' 0 0 1 'Downloaded the module dependencies'
mkdir -p "$work/vendor"
: >"$work/vendor/modules.txt"
STUB_GOWORK="$work/go.work" run 'a vendored workspace needs no download' 3 0 0 'needs no download'
echo 'PASS: module download retry and failure boundaries'
