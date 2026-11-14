#!/usr/bin/env bash
# Every Go validator job downloads the modules its restored cache did not supply,
# through the shared bounded retry, so a module-proxy blip is retried instead of
# failing the build, test or lint that follows (devantler-tech/.github#911). Pin
# that wiring, then drive the real script and the real retry helper; only the
# `go` process is a fixture. Which jobs call the action is pinned by
# test-go-module-cache-policy.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-$root/.github/actions/download-go-modules/action.yaml}"
fail() { echo "FAIL: $*" >&2; exit 1; }

wiring='
  .runs.steps[0] as $download |
  .runs.using == "composite" and (.runs.steps | length == 1) and
  $download.shell == "bash" and
  $download["working-directory"] == "${{ github.workspace }}" and
  $download.run == "bash \"$ACTION_PATH/download.sh\" \"$MODULE_DIR\" \"$ACTION_PATH/../../../.scripts/retry.sh\"" and
  $download.env.ACTION_PATH == "${{ github.action_path }}" and
  $download.env.MODULE_DIR == "${{ inputs.module-directory }}" and
  $download.env.RETRY_MAX_ATTEMPTS == "3" and
  $download.env.RETRY_BASE_DELAY == "5" and
  ($download["continue-on-error"] // false) == false and
  ($download.if // null) == null and
  .inputs["module-directory"].required == true
'
yq -o=json . "$action" | jq -e "$wiring" >/dev/null ||
  fail 'the job must run one unconditional, 3-attempt retried module download'
[[ -f "$(dirname "$action")/../../../.scripts/retry.sh" ]] || fail 'the shared retry helper must resolve from the action'
echo 'PASS: the module download is retried 3 times and cannot be skipped'

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
blocks 'a missing download' '.runs.steps = []'
blocks 'an unbounded attempt count' '.runs.steps[0].env |= del(.RETRY_MAX_ATTEMPTS)'
blocks 'more attempts' '.runs.steps[0].env.RETRY_MAX_ATTEMPTS = "5"'
blocks 'a download that cannot fail the job' '.runs.steps[0]["continue-on-error"] = true'
blocks 'a skippable download' '.runs.steps[0].if = "false"'
blocks 'an optional module directory' '.inputs["module-directory"].required = false'
blocks 'a download outside the retry' '.runs.steps[0].run = "go mod download"'

# Only the download is retried, and only downloads run: never a build, test or lint.
script="$root/.github/actions/download-go-modules/download.sh"
retry="$root/.scripts/retry.sh"
grep -qF 'bash "$retry" go mod download; then' "$script" ||
  fail 'the script must download the modules through the retry helper'
echo 'PASS: the script downloads the modules through the retry helper'

# Drive the real download script and retry helper. The fixture `go` fails the
# first FAILURES downloads the way the proxy does, then succeeds.
attempts="$(yq -r '.runs.steps[0].env.RETRY_MAX_ATTEMPTS' "$action")"
mkdir -p "$work/bin" "$work/module with spaces"
cat >"$work/bin/go" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$PWD" "$*" >>"$CALLS"
calls="$(wc -l <"$CALLS")"
if ((calls <= FAILURES)); then
  echo "verifying example.com/m@v1.0.0: $FAILURE_TEXT" >&2
  exit 1
fi
SH
chmod +x "$work/bin/go"
export PATH="$work/bin:$PATH" CALLS="$work/calls" RETRY_MAX_ATTEMPTS="$attempts" RETRY_BASE_DELAY=0
module="$work/module with spaces"
run() { # run <label> <failures> <failure-text> <want-exit> <want-calls> <expected-output>
  local label="$1" rc=0 out calls=0
  : >"$CALLS"
  out="$(cd "$work" && FAILURES="$2" FAILURE_TEXT="$3" bash "$script" "module with spaces" "$retry" 2>&1)" || rc=$?
  [[ -s "$CALLS" ]] && calls="$(wc -l <"$CALLS")"
  if [[ "$rc" != "$4" ]] || ((calls != $5)) || [[ "$out" != *"$6"* ]]; then
    printf 'FAIL: %s: wanted exit %s after %s downloads with %s; got exit %s after %s downloads\n%s\n' \
      "$label" "$4" "$5" "$6" "$rc" "$calls" "$out" >&2
    exit 1
  fi
  if grep -vqxF "$module|mod download" "$CALLS"; then
    fail "$label: Go ran outside the module or with other arguments: $(cat "$CALLS")"
  fi
  echo "PASS: $label"
}
stream='stream error: stream ID 1; INTERNAL_ERROR; received from peer'
run 'cached modules download once' 0 "$stream" 0 1 'Every Go module the job needs is available.'
run 'a transient proxy error is retried' 2 "$stream" 0 3 'Every Go module the job needs is available.'
run 'an unreachable proxy fails after the bounded retries' 3 "$stream" 1 3 'No build, test or lint step ran.'
# Each attempt's own error stays in the log, so nothing is hidden by the retry.
out="$(: >"$CALLS"; cd "$work" && FAILURES=2 FAILURE_TEXT="$stream" bash "$script" "module with spaces" "$retry" 2>&1)"
[[ "$(grep -cF "$stream" <<<"$out")" == 2 ]] || fail "each failed attempt's error must stay in the log: $out"
echo 'PASS: every failed attempt keeps its error in the log'
# A vendoring module builds from vendor/: the download must not reach the network.
mkdir -p "$module/vendor" && : >"$module/vendor/modules.txt"
run 'a vendoring module downloads nothing' 3 "$stream" 0 0 'vendors its dependencies'
rm -rf "$module/vendor"
# A checksum mismatch is not transient: it fails every attempt and still fails the job.
run 'a checksum mismatch still fails the job' 9 'checksum mismatch' 1 3 'No build, test or lint step ran.'
echo 'PASS: module download retry and failure boundaries'
