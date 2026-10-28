#!/usr/bin/env bash
# Prove the immutable offline wrapper retains every production step except its two dependencies.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
production="$root/actions/create-issues-from-todos/action.yaml"
fixture="$root/.github/actions/test-todo-default-fixture/action.yaml"
yq -o=json '.' "$production" >"$work/source.json"
yq -o=json '.' "$fixture" >"$work/fixture.json"
guard() {
  jq -e --slurpfile source "$work/source.json" '
    $source[0] as $p | . as $f |
    [$p.runs.steps | to_entries[] | select(.value.id == "app-token") | .key] as $tokens |
    [$p.runs.steps | to_entries[] | select((.value.uses // "") | startswith("actions/checkout@")) | .key] as $checkouts |
    if ($tokens | length) != 1 or ($checkouts | length) != 1 then false else
      $tokens[0] as $t | $checkouts[0] as $c |
      ($f.inputs["fixture-skip-app-token"] | del(.description)) == {required:false,default:"false"} and
      ($f.runs.steps[$t] | keys) == ["env","id","if","name","run","shell"] and
      $f.runs.steps[$t].id == "app-token" and
      $f.runs.steps[$t].name == $p.runs.steps[$t].name and
      $f.runs.steps[$t].shell == "bash" and
      $f.runs.steps[$t].run == "bash \"$ACTION_SCRIPT\" app-token" and
      $f.runs.steps[$t].env == {
        CLIENT_ID:"${{ inputs.client-id }}", APP_ID:"${{ inputs.app-id }}",
        APP_PRIVATE_KEY:"${{ inputs.app-private-key }}", PROJECT_PERMISSION:"write",
        OPTIONAL_PROJECT_AUTH:"${{ inputs.optional-project-auth }}", PROJECT:"${{ inputs.project }}",
        ACTION_SCRIPT:"${{ github.action_path }}/../../../.github/tests/todo-production-default-fixture.sh"} and
      $f.runs.steps[$t].if == ("${{ (" +
        ($p.runs.steps[$t].if | ltrimstr("${{ ") | rtrimstr(" }}")) +
        ") && inputs.fixture-skip-app-token != \u0027true\u0027 }}") and
      $f.runs.steps[$c] == {shell:"bash",run:"echo Offline checkout dependency: no workspace changes"} and
      all(range(0; $p.runs.steps | length); . as $i |
        if $i != $t and $i != $c and ($p.runs.steps[$i] | has("run")) then
          $f.runs.steps[$i].run == ($p.runs.steps[$i].run |
            split("${GITHUB_ACTION_PATH}/../../") | join("${GITHUB_ACTION_PATH}/../../../"))
        else true end) and
      (($f | .name=$p.name | .description=$p.description |
        del(.inputs["fixture-skip-app-token"]) |
        .runs.steps[$t]=$p.runs.steps[$t] | .runs.steps[$c]=$p.runs.steps[$c] |
        .runs.steps |= map(if has("run") then
          .run |= (split("${GITHUB_ACTION_PATH}/../../../") | join("${GITHUB_ACTION_PATH}/../../"))
          else . end)) == $p)
    end
  ' "$1" >/dev/null
}
guard "$work/fixture.json" || fail 'immutable fixture changed production logic or dependency boundaries'
while IFS=$'\t' read -r label mutation; do
  jq "$mutation" "$work/fixture.json" >"$work/bad.json"
  jq -e --slurp ' .[0] != .[1] ' "$work/fixture.json" "$work/bad.json" >/dev/null || fail "mutation did not change source: $label"
  if guard "$work/bad.json"; then fail "accepted $label"; fi
  echo "PASS: rejects $label"
done <<'CASES'
real token action	.runs.steps[1].uses="actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"
missing skip refusal	.runs.steps[1].if="true"
wrong project forwarding	.runs.steps[1].env.PROJECT=""
unexpected token input	.inputs["app-private-key"].default="fictional-fixture-value"
real checkout	.runs.steps[4]={uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"}
different compiler	.runs.steps[2].with["go-version"]="1.1.0"
wrong source depth	.runs.steps[3].run |= (split("${GITHUB_ACTION_PATH}/../../../")|join("${GITHUB_ACTION_PATH}/../../"))
extra execution	.runs.steps += [{shell:"bash",run:"echo unexpected"}]
CASES
bash "$root/.github/scripts/generate-todo-default-action.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/fixture.json" >"$work/checked.json"
cmp -s "$work/generated.json" "$work/checked.json" || fail 'generated immutable action is stale'

# Execute the real preservation step at its private-action directory depth.
jq -er '.runs.steps[] | select(.name=="🧰 Preserve retry helper") | .run' "$work/fixture.json" >"$work/preserve.sh"
mkdir -p "$work/compiler-runtime"
env GITHUB_ACTION_PATH="$root/.github/actions/test-todo-default-fixture" \
  RUNNER_TEMP="$work/compiler-runtime" bash -euo pipefail "$work/preserve.sh"
[[ -x "$work/compiler-runtime/devantler-todo-guard" ]] || fail 'supervisor compiler did not produce its real executable'
cmp "$root/.scripts/retry.sh" "$work/compiler-runtime/devantler-actions-retry.sh" || fail 'wrong retry helper source'

# Run the wrapper's actual dependency body; never fabricate its execution receipt.
jq -er '.runs.steps[] | select(.id=="app-token") | .run' "$work/fixture.json" >"$work/token.sh"
export RUNNER_TEMP="$work/runtime" GITHUB_OUTPUT="$work/outputs"
export OPTIONAL_PROJECT_AUTH=false PROJECT=organization/devantler-tech/5 PROJECT_PERMISSION=write
export CLIENT_ID='' APP_ID='' APP_PRIVATE_KEY=''
export ACTION_SCRIPT="$root/.github/tests/todo-production-default-fixture.sh"
mkdir -p "$RUNNER_TEMP/todo-action-smoke"
bash "$work/token.sh"
grep -Fxq 'token=offline-project-token' "$GITHUB_OUTPUT"
jq -e '. == {flag:"false",project:"organization/devantler-tech/5",token:"offline-project-token"}' \
  "$RUNNER_TEMP/todo-action-smoke/app-token.json" >/dev/null
if bash "$work/token.sh" >"$work/repeated.log" 2>&1; then fail 'duplicate token execution was accepted'; fi
for field in PROJECT OPTIONAL_PROJECT_AUTH PROJECT_PERMISSION APP_PRIVATE_KEY; do
  rm -f "$RUNNER_TEMP/todo-action-smoke/app-token.json"
  : >"$GITHUB_OUTPUT"
  if env "$field=fictional-invalid-value" bash "$work/token.sh" >"$work/refusal.log" 2>&1; then
    fail "accepted invalid $field"
  fi
  [[ ! -e "$RUNNER_TEMP/todo-action-smoke/app-token.json" && ! -s "$GITHUB_OUTPUT" ]] ||
    fail 'invalid dependency inputs emitted a token receipt'
done
echo 'PASS: immutable source parity, eight source mutations and actual token execution/refusal controls'
