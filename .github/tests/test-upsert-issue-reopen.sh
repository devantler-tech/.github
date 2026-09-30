#!/usr/bin/env bash

# Exercise the action's actual run block against an offline GitHub CLI fixture.
# Cover issue lifecycle, exact payloads and outputs, body inputs, and API failures.
#
# The action tracks a recurring failure with one issue. When the matching issue is closed, the
# step must reopen it, and a reopen that keeps failing must fail the step: otherwise the body is
# updated, the step succeeds, and the failure the issue exists to surface stays hidden.
#
# The reopen decision reads the issue's live state rather than the title search, because the
# search index can still report an issue as open moments after it was closed. Open and closed
# matches are searched separately, so a long history of closed copies cannot hide an open one.

set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
action="${1:-$root/actions/upsert-issue/action.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

yq -r '.runs.steps[] | select(.id == "upsert") | .run' "$action" >"$work/upsert.sh"
[[ -s "$work/upsert.sh" ]] || {
  echo "FAIL: no run block extracted from $action" >&2
  exit 1
}

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Records every call and answers from the scenario the test configured.
set -uo pipefail
printf '%s\n' "$*" >>"$STUB_DIR/calls"
jq -cn --args '$ARGS.positional' -- "$@" >>"$STUB_DIR/argv"
case "$1 $2" in
  "issue list")
    [[ "${STUB_LIST_RC:-0}" -eq 0 ]] || exit "$STUB_LIST_RC"
    state=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--state" ]] && state="$2"
      shift
    done
    case "$state" in
      open) printf '%s\n' "$STUB_OPEN_JSON" ;;
      closed) printf '%s\n' "$STUB_CLOSED_JSON" ;;
      *)
        echo "stub gh: unexpected call: issue list without --state open|closed" >&2
        exit 97
        ;;
    esac
    ;;
  "issue view")
    [[ "$STUB_VIEW_RC" -eq 0 ]] || exit "$STUB_VIEW_RC"
    printf '%s\n' "$STUB_LIVE_STATE"
    ;;
  "issue edit") exit "$STUB_EDIT_RC" ;;
  "issue close") exit "$STUB_CLOSE_RC" ;;
  "issue create")
    [[ "$STUB_CREATE_RC" -eq 0 ]] || exit "$STUB_CREATE_RC"
    printf '%s\n' "$STUB_CREATED_URL"
    ;;
  "issue reopen")
    attempts=$(( $(cat "$STUB_DIR/reopens" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$attempts" >"$STUB_DIR/reopens"
    # Fail the first STUB_REOPEN_FAILURES attempts, then succeed.
    [[ "$attempts" -gt "${STUB_REOPEN_FAILURES:-0}" ]] || {
      echo "HTTP 502: Bad Gateway" >&2
      exit 1
    }
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 97
    ;;
esac
STUB
chmod +x "$work/bin/gh"

failures=0

# run_case <label> <open> <open-json> <closed-json> <live-state> <reopen-failures> <list-rc>
#          <want-rc> <want-reopens> <want-closes> <want-creates> <want-issue>
run_case() {
  local label="$1" open_input="$2" open_json="$3" closed_json="$4" live="$5" reopen_failures="$6"
  local list_rc="$7" want_rc="$8" want_reopens="$9" want_closes="${10}" want_creates="${11}"
  local want_issue="${12}" dir rc=0 out reopens closes creates issue url problem=""
  local body="${TEST_BODY-body}" body_file="" expected_body="${TEST_BODY-body}"
  local labels="${TEST_LABELS:-}" repo="${TEST_REPO:-owner/repo}" comment="${TEST_COMMENT:-closed}"
  dir="$(mktemp -d "$work/case.XXXXXX")"
  : >"$dir/calls"
  : >"$dir/argv"
  : >"$dir/output"
  case "${TEST_BODY_FILE:-}" in
    present)
      body_file="$dir/body.md"
      printf '%s\n' "${TEST_FILE_BODY-file body}" >"$body_file"
      expected_body="$(cat "$body_file")"
      ;;
    missing) body_file="$dir/missing.md" ;;
  esac
  out="$(
    PATH="$work/bin:$PATH" \
      STUB_DIR="$dir" STUB_OPEN_JSON="$open_json" STUB_CLOSED_JSON="$closed_json" \
      STUB_LIVE_STATE="$live" STUB_REOPEN_FAILURES="$reopen_failures" STUB_LIST_RC="$list_rc" \
      STUB_EDIT_RC="${TEST_EDIT_RC:-0}" STUB_VIEW_RC="${TEST_VIEW_RC:-0}" \
      STUB_CLOSE_RC="${TEST_CLOSE_RC:-0}" STUB_CREATE_RC="${TEST_CREATE_RC:-0}" \
      STUB_CREATED_URL="${TEST_CREATED_URL:-https://github.com/$repo/issues/99}" \
      GITHUB_ACTION_PATH="$root/actions/upsert-issue" GITHUB_OUTPUT="$dir/output" \
      RETRY_MAX_ATTEMPTS=3 RETRY_BASE_DELAY=0 RETRY_MAX_DELAY=0 \
      TITLE="Tracking issue" BODY="$body" BODY_FILE="$body_file" LABELS="$labels" OPEN="$open_input" \
      CLOSE_COMMENT="$comment" REPO="$repo" GH_TOKEN="offline-fixture" GITHUB_TOKEN="" \
      bash "$work/upsert.sh" 2>&1
  )" || rc=$?
  reopens="$(grep -c '^issue reopen ' "$dir/calls" || true)"
  closes="$(grep -c '^issue close ' "$dir/calls" || true)"
  creates="$(grep -c '^issue create ' "$dir/calls" || true)"
  issue="$(sed -n 's/^issue-number=//p' "$dir/output")"
  url="$(sed -n 's/^issue-url=//p' "$dir/output")"

  [[ "$rc" == "$want_rc" ]] || problem="exit ${rc}, want ${want_rc}"
  [[ -n "$problem" || "$reopens" == "$want_reopens" ]] || problem="${reopens} reopen call(s), want ${want_reopens}"
  [[ -n "$problem" || "$closes" == "$want_closes" ]] || problem="${closes} close call(s), want ${want_closes}"
  [[ -n "$problem" || "$creates" == "$want_creates" ]] || problem="${creates} create call(s), want ${want_creates}"
  [[ -n "$problem" || "$issue" == "$want_issue" ]] || problem="issue-number '${issue}', want '${want_issue}'"
  if [[ -z "$problem" && -n "$want_issue" && "$url" != "https://github.com/$repo/issues/$want_issue" ]]; then
    problem="issue-url does not match the selected repository and issue"
  elif [[ -z "$problem" && -z "$want_issue" && -s "$dir/output" ]]; then
    problem="failure or no-op published issue outputs"
  fi
  if [[ -z "$problem" ]] && ! jq -se --arg repo "$repo" --arg body "$expected_body" \
    --arg labels "$labels" --arg comment "$comment" --arg open "$open_input" --arg issue "$want_issue" '
      def flag($name): .[index($name) + 1];
      all(.[]; index("--repo") != null and flag("--repo") == $repo) and
      all(.[] | select(.[1] == "create" or (.[1] == "edit" and index("--body") != null));
        flag("--body") == $body) and
      all(.[] | select(.[1] == "create"); flag("--title") == "Tracking issue") and
      all(.[] | select(.[1] == "close"); flag("--comment") == $comment) and
      (if $open == "true" and $issue != "" then
        any(.[]; .[1] == "create" or (.[1] == "edit" and index("--body") != null))
      else true end) and
      (if $open == "true" and $issue != "" and $labels != "" then
        any(.[]; (index("--label") != null and flag("--label") == $labels) or
          (index("--add-label") != null and flag("--add-label") == $labels))
      else true end)
    ' "$dir/argv" >/dev/null; then
    problem="CLI arguments lost the repository, body, labels or close comment"
  fi
  if [[ -z "$problem" && -n "${TEST_DIAGNOSTIC:-}" ]]; then
    if [[ -s "$dir/calls" ]] || ! grep -qF "$TEST_DIAGNOSTIC" <<<"$out"; then
      problem="invalid body input reached the API or lacked its diagnostic"
    fi
  fi
  if [[ -z "$problem" ]] && grep -q 'unexpected call' <<<"$out"; then
    problem="the stub saw an unexpected gh call"
  fi
  if [[ -n "$problem" ]]; then
    echo "FAIL: ${label} — ${problem}; calls: $(tr '\n' ';' <"$dir/calls"); output: ${out}" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok: ${label}"
}

none='[]'
one='[{"number":7,"title":"Tracking issue"}]'
other='[{"number":3,"title":"Tracking issue (old)"}]'
# Numbers deliberately out of order, with a near-miss title that must be ignored.
several='[{"number":12,"title":"Tracking issue"},{"number":40,"title":"Tracking issue"},{"number":5,"title":"Tracking issue"},{"number":90,"title":"Tracking issue (old)"}]'

# Columns: label, open, open-json, closed-json, live state, reopen failures, list exit code,
# then the expected exit code, reopens, closes, creates and issue number.
run_case "a closed issue is reopened" true "$none" "$one" CLOSED 0 0 0 1 0 0 7
run_case "a transient reopen failure is retried" true "$none" "$one" CLOSED 1 0 0 2 0 0 7
run_case "a reopen that keeps failing fails the step" true "$none" "$one" CLOSED 3 0 1 3 0 0 ""
run_case "an open issue is not sent a reopen" true "$one" "$none" OPEN 0 0 0 0 0 0 7
run_case "a stale open search result still reopens" true "$one" "$none" CLOSED 0 0 0 1 0 0 7
run_case "no matching issue creates one without a reopen" true "$other" "$other" CLOSED 0 0 0 0 0 1 99
run_case "the newest of several open matches is used" true "$several" "$one" OPEN 0 0 0 0 0 0 40
run_case "an open match wins over any closed match" true "$one" "$several" OPEN 0 0 0 0 0 0 7
run_case "the newest of several closed matches is reopened" true "$none" "$several" CLOSED 0 0 0 1 0 0 40
run_case "a failed search fails the step and never creates" true "$none" "$none" CLOSED 0 1 1 0 0 0 ""

# Closing: an open issue is closed once; an already-closed one is left alone.
run_case "an open issue is closed" false "$one" "$none" OPEN 0 0 0 0 1 0 7
run_case "an already-closed issue is not closed again" false "$none" "$one" CLOSED 0 0 0 0 0 0 7
run_case "no matching issue is a no-op when closing" false "$none" "$other" CLOSED 0 0 0 0 0 0 ""
run_case "a failed search fails the closing step too" false "$none" "$none" OPEN 0 1 1 0 0 0 ""

TEST_BODY=$'a quoted "body"\nwith a second line' TEST_LABELS="bug,automation" TEST_REPO="offline/consumer" \
  run_case "create preserves payload, labels and target repository" true "$none" "$none" OPEN 0 0 0 0 0 1 99
TEST_BODY="ignored inline body" TEST_BODY_FILE=present TEST_FILE_BODY=$'file "body"\nnext line' TEST_LABELS="bug" \
  run_case "body file wins when updating and adding labels" true "$one" "$none" OPEN 0 0 0 0 0 0 7
TEST_COMMENT=$'resolved "report"\nnext line' \
  run_case "close preserves its comment" false "$one" "$none" OPEN 0 0 0 0 1 0 7
TEST_BODY="" TEST_DIAGNOSTIC="Either 'body' or 'body-file' input must be provided" \
  run_case "missing body fails before any API call" true "$none" "$none" OPEN 0 0 1 0 0 0 ""
TEST_BODY_FILE=missing TEST_DIAGNOSTIC="'body-file' not found:" \
  run_case "missing body file fails before any API call" true "$none" "$none" OPEN 0 0 1 0 0 0 ""
TEST_BODY_FILE=present TEST_FILE_BODY="" TEST_DIAGNOSTIC="Either 'body' or 'body-file' input must be provided" \
  run_case "empty body file fails before any API call" true "$none" "$none" OPEN 0 0 1 0 0 0 ""
TEST_CREATE_RC=1 \
  run_case "failed create is never retried or reported successful" true "$none" "$none" OPEN 0 0 1 0 0 1 ""
TEST_EDIT_RC=1 \
  run_case "failed update does not publish outputs" true "$one" "$none" OPEN 0 0 1 0 0 0 ""
TEST_VIEW_RC=1 \
  run_case "failed state lookup does not publish outputs" true "$one" "$none" OPEN 0 0 1 0 0 0 ""
TEST_CLOSE_RC=1 \
  run_case "failed close exhausts retries without success outputs" false "$one" "$none" OPEN 0 0 1 0 3 0 ""
TEST_CREATED_URL="not-an-issue-url" \
  run_case "malformed create response cannot publish outputs" true "$none" "$none" OPEN 0 0 1 0 0 1 ""
run_case "malformed search data never creates a duplicate" true "invalid" "$none" OPEN 0 0 1 0 0 0 ""

[[ "$failures" -eq 0 ]] || {
  echo "FAIL: ${failures} upsert-issue case(s) failed" >&2
  exit 1
}
echo "PASS: 26 offline upsert-issue cases preserve lifecycle, payloads, outputs and failure boundaries"
