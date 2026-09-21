#!/usr/bin/env bash
# Pins the workflow execution policy validator against fixtures, then checks the reviewed files.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validate="$repo_root/scripts/validate-workflow-execution-policies.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "workflow-execution-policies test: $*" >&2
  exit 1
}

# A valid base policy. Each case below changes exactly one thing about it.
base='{
  "name": "base",
  "enforcement": "evaluate",
  "conditions": {"repository_name": {"include": ["~ALL"], "exclude": []}},
  "rules": [
    {"type": "restrict_action_events", "parameters": {"allowed_events": ["push", "pull_request"]}},
    {"type": "restrict_actions_actors", "parameters": {"allowed_actors": [{"id": 26203420, "type": "User"}]}}
  ]
}'

# expect <case> <want-exit> <jq-edit> [<message-fragment>]
expect() {
  local name="$1" want="$2" edit="$3" fragment="${4:-}" dir out rc
  dir="$tmp/$name"
  mkdir "$dir"
  jq "$edit" <<<"$base" >"$dir/policy.json"
  rc=0
  out="$(bash "$validate" "$dir" 2>&1)" || rc=$?
  [ "$rc" = "$want" ] || fail "$name: exit $rc, want $want: $out"
  if [ -n "$fragment" ]; then
    grep -qF -- "$fragment" <<<"$out" || fail "$name: output lacks '$fragment': $out"
  fi
}

expect valid 0 '.'
expect disabled 0 '.enforcement = "disabled"'
expect active 1 '.enforcement = "active"' 'active needs maintainer approval'
expect unknown-enforcement 1 '.enforcement = "enforce"' 'is not evaluate or disabled'
expect empty-name 1 '.name = ""' 'name must be a non-empty string'
expect no-rules 1 '.rules = []' 'rules must be a non-empty array'
expect unknown-rule 1 '.rules[0].type = "restrict_everything"' 'rule type "restrict_everything"'
expect unknown-event 1 '.rules[0].parameters.allowed_events += ["pull_request_merged"]' 'event "pull_request_merged"'
expect empty-events 1 '.rules[0].parameters.allowed_events = []' 'needs a non-empty allowed_events'
expect string-actor-id 1 '.rules[1].parameters.allowed_actors[0].id = "26203420"' 'is not an integer'
expect fractional-actor-id 1 '.rules[1].parameters.allowed_actors[0].id = 1.5' 'is not an integer'
expect unknown-actor-type 1 '.rules[1].parameters.allowed_actors[0].type = "Login"' 'actor type "Login"'
expect empty-actors 1 '.rules[1].parameters.allowed_actors = []' 'needs a non-empty allowed_actors'
expect pull-request-target 1 '.rules[0].parameters.allowed_events += ["pull_request_target"]' \
  'allows pull_request_target without an exception'
expect workflow-run 1 '.rules[0].parameters.allowed_events += ["workflow_run"]' \
  'allows workflow_run without an exception'
# An exception needs both halves: the paths it covers and the reasoning a reviewer approved.
expect exception-without-threat-model 1 \
  '.rules[0].parameters.allowed_events += ["workflow_run"] | .exception = {"workflow_paths": [".github/workflows/x.yaml"]}' \
  'without an exception'
expect exception-without-paths 1 \
  '.rules[0].parameters.allowed_events += ["workflow_run"] | .exception = {"workflow_paths": [], "threat_model": "reads no PR code"}' \
  'without an exception'
expect documented-exception 0 \
  '.rules[0].parameters.allowed_events += ["workflow_run"] | .exception = {"workflow_paths": [".github/workflows/x.yaml"], "threat_model": "reads no PR code"}'
expect no-repository-target 1 'del(.conditions.repository_name)' 'exactly one of repository_name'
expect two-repository-targets 1 '.conditions.repository_id = {"repository_ids": [1]}' 'exactly one of repository_name'
expect all-mixed-into-include 1 '.conditions.workflow_path = {"include": ["~ALL", ".github/workflows/cd.yaml"], "exclude": []}' \
  'mixes ~ALL'
expect all-in-exclude 1 '.conditions.workflow_path = {"include": ["~ALL"], "exclude": ["~ALL"]}' \
  'exclude may not contain ~ALL'

# Not JSON at all.
mkdir "$tmp/broken"
printf '{"name": ' >"$tmp/broken/policy.json"
rc=0
out="$(bash "$validate" "$tmp/broken" 2>&1)" || rc=$?
if [ "$rc" != 1 ] || ! grep -qF 'not valid JSON' <<<"$out"; then
  fail "broken: exit $rc: $out"
fi

# An empty directory is not a passing policy set.
mkdir "$tmp/empty"
rc=0
bash "$validate" "$tmp/empty" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "empty directory: exit $rc, want 2"

# One bad file fails the set even when another passes.
mkdir "$tmp/mixed"
jq . <<<"$base" >"$tmp/mixed/a.json"
jq '.enforcement = "active"' <<<"$base" >"$tmp/mixed/b.json"
rc=0
bash "$validate" "$tmp/mixed" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "mixed: exit $rc, want 1"

# The reviewed policy files in this repository.
bash "$validate" >/dev/null || fail "reviewed policy files: $(bash "$validate" 2>&1 || true)"

echo "workflow-execution-policies test: ok"
