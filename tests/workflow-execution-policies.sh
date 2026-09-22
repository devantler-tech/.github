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
  "enforcement": "disabled",
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
expect evaluate 1 '.enforcement = "evaluate"' 'evaluate needs GitHub Enterprise Cloud'
expect active 1 '.enforcement = "active"' 'active needs maintainer approval'
expect unknown-enforcement 1 '.enforcement = "enforce"' 'is not disabled'
expect empty-name 1 '.name = ""' 'name must be a non-empty string'
# A mistyped optional field would otherwise be dropped silently, so only documented keys pass.
expect unknown-top-level-key 1 '.enforcment = "evaluate"' 'unknown key "enforcment"'
expect unknown-condition-key 1 '.conditions.workflow_paths = {"include": ["~ALL"], "exclude": []}' \
  'unknown condition "workflow_paths"'
expect exception-key-allowed 0 '.exception = {"workflow_paths": [".github/workflows/x.yaml"], "threat_model": "t"}'
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
# A valid exception is bound to what the policy targets: the policy covers exactly the excepted paths.
x='.rules[0].parameters.allowed_events += ["workflow_run"]
  | .conditions.workflow_path = {"include": [".github/workflows/x.yaml"], "exclude": []}
  | .conditions.repository_name.include = ["x"]
  | .exception = {"workflow_paths": [".github/workflows/x.yaml"], "threat_model": "reads no PR code"}'
expect documented-exception 0 "$x"
# An exception on an untargeted policy would lift the prohibition for every workflow.
expect exception-untargeted 1 "$x | del(.conditions.workflow_path)" 'targets workflow paths the exception does not list'
expect exception-on-all 1 "$x | .conditions.workflow_path.include = [\"~ALL\"]" 'targets workflow paths the exception does not list'
expect exception-other-path 1 "$x | .conditions.workflow_path.include += [\".github/workflows/y.yaml\"]" \
  'targets workflow paths the exception does not list'
expect exception-blank-path 1 "$x | .exception.workflow_paths += [\"\"]" 'without an exception'
expect exception-number-path 1 "$x | .exception.workflow_paths = [1]" 'without an exception'
expect no-repository-target 1 'del(.conditions.repository_name)' 'exactly one of repository_name'
expect two-repository-targets 1 '.conditions.repository_id = {"repository_ids": [1]}' 'exactly one of repository_name'
expect all-mixed-into-include 1 '.conditions.workflow_path = {"include": ["~ALL", ".github/workflows/cd.yaml"], "exclude": []}' \
  'mixes ~ALL'
expect all-in-exclude 1 '.conditions.workflow_path = {"include": ["~ALL"], "exclude": ["~ALL"]}' \
  'exclude may not contain ~ALL'
# Condition values must have the request shape, not only the right keys.
expect null-repository-name 1 '.conditions.repository_name = null' 'repository_name must be an object with an include array'
expect repository-name-no-include 1 '.conditions.repository_name = {"exclude": []}' 'repository_name must be an object with an include array'
expect repository-id-not-ints 1 'del(.conditions.repository_name) | .conditions.repository_id = {"repository_ids": ["x"]}' \
  'repository_id must be an object with an integer repository_ids array'
expect repository-property-no-include 1 'del(.conditions.repository_name) | .conditions.repository_property = {}' \
  'repository_property must be an object with an include array'
expect empty-workflow-path 1 '.conditions.workflow_path = {}' 'workflow_path must be an object with include and exclude arrays'
expect string-workflow-path 1 '.conditions.workflow_path = {"include": "~ALL", "exclude": []}' \
  'workflow_path must be an object with include and exclude arrays'
expect null-workflow-path 1 '.conditions.workflow_path = null' 'workflow_path must be an object with include and exclude arrays'
# The members of those arrays need the request shape too.
expect repository-name-numeric-member 1 '.conditions.repository_name.include = [7]' \
  'repository_name include and exclude must hold non-empty strings'
expect repository-name-numeric-exclude 1 '.conditions.repository_name.exclude = [7]' \
  'repository_name include and exclude must hold non-empty strings'
expect repository-property-member-no-name 1 \
  'del(.conditions.repository_name) | .conditions.repository_property = {"include": [{"property_values": ["x"]}]}' \
  'repository_property include members need a name and non-empty property_values'
expect repository-property-member-no-values 1 \
  'del(.conditions.repository_name) | .conditions.repository_property = {"include": [{"name": "tier"}]}' \
  'repository_property include members need a name and non-empty property_values'
expect repository-property-valid 0 \
  'del(.conditions.repository_name) | .conditions.repository_property = {"include": [{"name": "tier", "property_values": ["prod"]}]}'
expect workflow-path-no-patterns 1 '.conditions.workflow_path = {"include": [], "exclude": []}' \
  'workflow_path needs at least one include or exclude pattern'
expect workflow-path-empty-pattern 1 '.conditions.workflow_path = {"include": [""], "exclude": []}' \
  'workflow_path include and exclude must hold non-empty strings'

# Naming files is reviewable only against one repository: ci.yaml deploys in one repository and
# only tests in another, so the same path would restrict a different workflow elsewhere.
named='.conditions.workflow_path = {"include": [".github/workflows/cd.yaml"], "exclude": []}'
single="specific files, so repository_name must include exactly one repository"
expect named-files-one-repository 0 "$named | .conditions.repository_name.include = [\"platform\"]"
expect named-files-all-repositories 1 "$named" "$single"
expect named-files-two-repositories 1 "$named | .conditions.repository_name.include = [\"platform\", \"ksail\"]" "$single"
expect named-files-glob-repository 1 "$named | .conditions.repository_name.include = [\"plat*\"]" "$single"
expect named-files-repository-excluded 1 "$named | .conditions.repository_name = {\"include\": [\"platform\"], \"exclude\": [\"platform\"]}" "$single"
expect named-files-by-property 1 \
  "$named | del(.conditions.repository_name) | .conditions.repository_property = {\"include\": [{\"name\": \"tier\", \"property_values\": [\"prod\"]}]}" "$single"
expect all-files-all-repositories 0 '.conditions.workflow_path = {"include": ["~ALL"], "exclude": []}'

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
