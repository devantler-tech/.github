#!/usr/bin/env bash
# Pins the policy reconciler against an offline stand-in for GitHub's Actions policies API.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apply="$repo_root/scripts/apply-workflow-execution-policies.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "apply-workflow-execution-policies test: $*" >&2
  exit 1
}

# The stand-in keeps the organization's live policies in $GH_STATE, logs every call to $GH_LOG
# and every request body to $GH_BODIES. Knobs: FAIL_LIST and FAIL_WRITE make those calls fail,
# BAD_SHAPE returns a list in the wrong shape, EXTRA_TOTAL inflates the reported total, and
# MANGLE_PATHS stores workflow paths in a different form from the one sent.
bin="$tmp/bin"
mkdir "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "fake gh: only api is supported" >&2; exit 2; }
shift
method=GET
input=""
endpoint=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$endpoint" >>"$GH_LOG"
state="$GH_STATE"
# store <id> <method>: an update that omits workflow_path keeps the policy's existing workflow
# targeting, as GitHub documents for PUT; a create stores only what was sent.
store() {
  jq --argjson id "$1" --arg method "$2" --slurpfile body "$input" --arg mangle "${MANGLE_PATHS-}" '
    (map(select(.id == $id)) | first // {}) as $old
    | ($body[0] + {id: $id, source_type: "Organization", target: "actions"}
      | if $method == "PUT" and .conditions.workflow_path == null and $old.conditions.workflow_path != null then
          .conditions.workflow_path = $old.conditions.workflow_path
        else . end
      | if $mangle == "1" and .conditions.workflow_path then
          .conditions.workflow_path.include |= map("example/" + .)
        else . end) as $p
    | if any(.[]; .id == $id) then map(if .id == $id then $p else . end) else . + [$p] end' \
    "$state" >"$state.next"
  mv "$state.next" "$state"
  jq --argjson id "$1" 'map(select(.id == $id)) | first' "$state"
}
case "$method $endpoint" in
  "GET orgs/fix/actions/policies?"*)
    [ "${FAIL_LIST-}" != 1 ] || { echo "HTTP 500: Internal Error" >&2; exit 1; }
    [ "${BAD_SHAPE-}" != 1 ] || { echo '[]'; exit 0; }
    page="${endpoint#*&page=}"
    page="${page%%&*}"
    jq --argjson page "$page" --argjson extra "${EXTRA_TOTAL-0}" \
      '{total_count: (length + $extra), policies: .[($page - 1) * 100 : $page * 100]}' "$state"
    ;;
  "POST orgs/fix/actions/policies")
    [ "${FAIL_WRITE-}" != 1 ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    jq -c . "$input" >>"$GH_BODIES"
    store "$(jq '(map(.id) | max // 0) + 1' "$state")" POST
    ;;
  "PUT orgs/fix/actions/policies/"*)
    [ "${FAIL_WRITE-}" != 1 ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
    jq -c . "$input" >>"$GH_BODIES"
    store "${endpoint##*/}" PUT
    ;;
  "GET orgs/fix/actions/policies/"*)
    found="$(jq --argjson id "${endpoint##*/}" 'map(select(.id == $id)) | first // empty' "$state")"
    [ -n "$found" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    printf '%s\n' "$found"
    ;;
  *)
    echo "fake gh: unexpected $method $endpoint" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$bin/gh"

# Two reviewed policies: an organization-wide event rule, and an actor rule on one repository's
# named workflow file whose review-only exception must never reach the API.
policies="$tmp/policies"
mkdir "$policies"
cat >"$policies/events.json" <<'JSON'
{
  "name": "Allow observed events",
  "enforcement": "disabled",
  "conditions": {"repository_name": {"include": ["~ALL"], "exclude": []}},
  "rules": [{"type": "restrict_action_events", "parameters": {"allowed_events": ["push", "pull_request", "schedule"]}}]
}
JSON
cat >"$policies/starters.json" <<'JSON'
{
  "name": "Restrict deploy starters in example",
  "enforcement": "disabled",
  "conditions": {
    "repository_name": {"include": ["example"], "exclude": []},
    "workflow_path": {"include": [".github/workflows/cd.yaml"], "exclude": []}
  },
  "rules": [
    {"type": "restrict_actions_actors", "parameters": {"allowed_actors": [
      {"id": 26203420, "type": "User"},
      {"id": 118344674, "type": "Bot"}
    ]}}
  ],
  "exception": {"workflow_paths": [".github/workflows/cd.yaml"], "threat_model": "review record only"}
}
JSON

# The live copies of those two files, as GitHub stores them.
in_sync='[
  {"id": 1, "name": "Allow observed events", "enforcement": "disabled", "source_type": "Organization",
   "conditions": {"repository_name": {"include": ["~ALL"], "exclude": []}},
   "rules": [{"type": "restrict_action_events", "parameters": {"allowed_events": ["push", "pull_request", "schedule"]}}]},
  {"id": 2, "name": "Restrict deploy starters in example", "enforcement": "disabled", "source_type": "Organization",
   "conditions": {"repository_name": {"include": ["example"], "exclude": []},
                  "workflow_path": {"include": [".github/workflows/cd.yaml"], "exclude": []}},
   "rules": [{"type": "restrict_actions_actors", "parameters": {"allowed_actors": [
     {"id": 26203420, "type": "User"}, {"id": 118344674, "type": "Bot"}]}}]}
]'

state="$tmp/state.json"
log="$tmp/gh.log"
bodies="$tmp/bodies.jsonl"
case=""
out=""

# reset <live-policies-json>
reset() {
  printf '%s\n' "$1" >"$state"
  : >"$log"
  : >"$bodies"
}

# run_apply <want-exit> [<apply argument>...]; leaves the combined output in $out
run_apply() {
  local want="$1" rc=0
  shift
  out="$(PATH="$bin:$PATH" GH_STATE="$state" GH_LOG="$log" GH_BODIES="$bodies" bash "$apply" --org fix "$@" 2>&1)" || rc=$?
  [ "$rc" = "$want" ] || fail "$case: exit $rc, want $want: $out"
}

expect_out() {
  grep -qF -- "$1" <<<"$out" || fail "$case: output lacks '$1': $out"
}

expect_writes() {
  local n
  n="$(grep -cE '^(POST|PUT) ' "$log" || true)"
  [ "$n" = "$1" ] || fail "$case: $n writes, want $1: $(cat "$log")"
}

case=create
reset '[]'
run_apply 0 --dir "$policies"
expect_out 'CREATED  events.json (id 1)'
expect_out 'CREATED  starters.json (id 2)'
expect_writes 2
# The exception is this repository's review record, not part of the request.
if grep -qF exception "$bodies"; then fail "$case: a request body carried the exception: $(cat "$bodies")"; fi
[ "$(jq length "$state")" = 2 ] || fail "$case: $(jq length "$state") live policies, want 2"

case=in-sync
: >"$log"
run_apply 0 --dir "$policies"
expect_out 'IN-SYNC  events.json'
expect_out 'IN-SYNC  starters.json'
expect_writes 0

# GitHub may list actors in another order and add fields of its own; neither is drift.
case=order-and-server-fields
reset "$(jq '.[1].rules[0].parameters.allowed_actors |= (reverse | map(. + {login: "someone"}))
  | map(. + {target: "actions", created_at: "2026-09-23T00:00:00Z", _links: {}})' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'IN-SYNC  starters.json'
expect_writes 0

case=update
reset "$(jq '.[1].enforcement = "active"' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'UPDATED  starters.json (id 2)'
expect_out 'IN-SYNC  events.json'
grep -qx 'PUT orgs/fix/actions/policies/2' "$log" || fail "$case: no PUT to policy 2: $(cat "$log")"
expect_writes 1
[ "$(jq -r '.[1].enforcement' "$state")" = disabled ] || fail "$case: policy 2 was not set back to disabled"

# A changed workflow_path is sent in full, so the update replaces it.
case=update-workflow-path
reset "$(jq '.[1].conditions.workflow_path.include = [".github/workflows/other.yaml"]' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'UPDATED  starters.json (id 2)'
expect_writes 1

# An update cannot remove workflow_path: GitHub keeps the live targeting when it is omitted, so
# the read-back has to fail loudly rather than report the policy as updated.
case=update-cannot-drop-workflow-path
reset "$(jq '.[0].conditions.workflow_path = {"include": [".github/workflows/x.yaml"], "exclude": []}' <<<"$in_sync")"
run_apply 1 --dir "$policies"
expect_out 'MISMATCH events.json: policy 1 was stored differently'
expect_writes 1

case=check-drift
reset "$(jq '.[1].enforcement = "active"' <<<"$in_sync")"
run_apply 1 --dir "$policies" --check
expect_out 'DRIFT    starters.json: the live policy (id 2) differs'
expect_writes 0

case=check-missing
reset '[]'
run_apply 1 --dir "$policies" --check
expect_out 'DRIFT    events.json: no live policy is named "Allow observed events"'
expect_writes 0

case=check-clean
reset "$in_sync"
run_apply 0 --dir "$policies" --check
expect_writes 0

# A policy made by hand is reported, never changed or deleted.
case=unmanaged
reset "$(jq '. + [{"id": 9, "name": "Made by hand", "enforcement": "active", "source_type": "Organization", "rules": []}]' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'UNMANAGED Made by hand (id 9): no file names it; left alone'
expect_writes 0
[ "$(jq length "$state")" = 3 ] || fail "$case: the unmanaged policy was removed"

# A policy an enterprise sets applies here but is not the organization's to change.
case=enterprise-policy
reset "$(jq '. + [{"id": 7, "name": "Allow observed events", "enforcement": "active", "source_type": "Enterprise", "rules": []}]' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'IN-SYNC  events.json'
if grep -qF 'id 7' <<<"$out"; then fail "$case: the enterprise policy was reported: $out"; fi
expect_writes 0

# GitHub storing something other than what was sent is exactly what the read-back is for.
case=read-back-mismatch
reset '[]'
MANGLE_PATHS=1 run_apply 1 --dir "$policies"
expect_out 'CREATED  events.json (id 1)'
expect_out 'MISMATCH starters.json: policy 2 was stored differently'
expect_out 'example/.github/workflows/cd.yaml'

case=write-refused
reset '[]'
FAIL_WRITE=1 run_apply 1 --dir "$policies"
expect_out 'FAILED   events.json: HTTP 403'
expect_out 'FAILED   starters.json: HTTP 403'

# Without the complete live list, a write could duplicate a policy on an unread page.
case=list-failed
reset "$in_sync"
FAIL_LIST=1 run_apply 2 --dir "$policies"
expect_out 'UNKNOWN could not list'
expect_writes 0

case=list-bad-shape
reset "$in_sync"
BAD_SHAPE=1 run_apply 2 --dir "$policies"
expect_out 'is not the documented shape'
expect_writes 0

case=list-incomplete
reset "$in_sync"
EXTRA_TOTAL=1 run_apply 2 --dir "$policies"
expect_out 'UNKNOWN read 2 of 3'
expect_writes 0

# 150 policies made by hand come first, so the managed ones are only on the second page.
case=pagination
reset "$(jq '[range(150) | {id: (. + 100), name: "Filler \(.)", enforcement: "disabled", source_type: "Organization", rules: []}] + .' <<<"$in_sync")"
run_apply 0 --dir "$policies"
expect_out 'IN-SYNC  events.json'
expect_out 'IN-SYNC  starters.json'
grep -qF 'page=2&' "$log" || fail "$case: the second page was never read: $(cat "$log")"
expect_writes 0

case=ambiguous-live-name
reset "$(jq '. + [.[1] + {id: 3}]' <<<"$in_sync")"
run_apply 1 --dir "$policies"
expect_out 'more than one live policy is named "Restrict deploy starters in example"'
expect_writes 0

# Files are checked before GitHub is read at all.
case=duplicate-file-names
dup="$tmp/duplicate"
mkdir "$dup"
cp "$policies/events.json" "$dup/a.json"
cp "$policies/events.json" "$dup/b.json"
reset '[]'
run_apply 1 --dir "$dup"
expect_out 'more than one file is named "Allow observed events"'
[ ! -s "$log" ] || fail "$case: GitHub was called: $(cat "$log")"

case=invalid-file
invalid="$tmp/invalid"
mkdir "$invalid"
jq '.enforcement = "active"' "$policies/events.json" >"$invalid/events.json"
reset '[]'
run_apply 1 --dir "$invalid"
expect_out 'active needs maintainer approval'
expect_out 'nothing was applied'
[ ! -s "$log" ] || fail "$case: GitHub was called: $(cat "$log")"

case=usage
rc=0
PATH="$bin:$PATH" bash "$apply" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "$case: exit $rc without --org, want 2"

# The reviewed policy files in this repository apply cleanly to an organization with none.
case=reviewed-files
reset '[]'
run_apply 0
want="$(find "$repo_root/workflow-execution-policies" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
got="$(grep -c '^CREATED ' <<<"$out" || true)"
[ "$got" = "$want" ] || fail "$case: $got created, want $want: $out"
if grep -qF exception "$bodies"; then fail "$case: a request body carried an exception"; fi

echo "apply-workflow-execution-policies test: ok"
