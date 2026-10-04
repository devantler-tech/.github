#!/usr/bin/env bash
# Replay the shipped alignment with real npm in disposable installation prefixes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/create-release.yaml"
mode="${1:-native}"
[[ "$mode" == native || "$mode" == --check-fixtures ]] || exit 2
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
default="$(yq -r '.on.workflow_call.inputs."align-npm-with-consumer-contract".default' "$workflow")"
[[ "$default" == true ]] || fail 'omitted npm alignment must enable the reviewed contract path'
yq -o=json '.' "$workflow" | jq -e '
  .on.workflow_call.inputs["align-npm-with-consumer-contract"].type == "boolean" and
  ([.jobs.release.steps[] | select(.name == "📦 Align npm with consumer contract") |
    select(.if == "${{ inputs.align-npm-with-consumer-contract }}" and .shell == "bash")] | length == 1) and
  ([.jobs.release.steps[] | select(.name == "📦 Setup Node.js") |
    select(.with["package-manager-cache"] == "${{ !inputs.align-npm-with-consumer-contract }}")] | length == 1)
' >/dev/null || fail 'unsupported alignment admission or pre-alignment npm cache probe'
yq -r '.jobs.release.steps[] | select(.name == "📦 Align npm with consumer contract") | .run' "$workflow" >"$work/alignment.sh"
[[ -s "$work/alignment.sh" ]] || fail 'missing production alignment body'
[[ "$mode" != --check-fixtures ]] || { echo 'PASS: omitted/explicit npm inputs bind to the shipped alignment path'; exit 0; }
base_path="$PATH"
base_version="$(npm --version)"
[[ "${base_version%%.*}" == 10 ]] || fail 'native proof requires the production Node 22 bundled npm 10'
mkdir -p "$work/cache"
: >"$work/user.npmrc"
: >"$work/global.npmrc"
run_case() {
  local name="$1" setting="$2" contract="$3" expected="$4" enabled prefix workspace runner version
  enabled="${setting:-$default}"
  [[ "$enabled" == true || "$enabled" == false ]] || fail 'invalid caller setting'
  prefix="$work/$name/prefix"
  workspace="$work/$name/workspace"
  runner="$work/$name/runner"
  mkdir -p "$prefix" "$workspace" "$runner"
  printf '%s\n' "$contract" >"$workspace/package.json"
  if [[ "$enabled" == true ]]; then
    # A new prefix intentionally leaves the bundled executable untouched. Disable
    # Bash command hashing so the newly installed prefix is resolved on the next call.
    if ! (
      cd "$workspace"
      # shellcheck disable=SC2016 # $1 expands in the inner Bash process.
      env -i PATH="$prefix/bin:$base_path" GITHUB_WORKSPACE="$workspace" RUNNER_TEMP="$runner" \
        npm_config_prefix="$prefix" npm_config_cache="$work/cache" \
        npm_config_userconfig="$work/user.npmrc" npm_config_globalconfig="$work/global.npmrc" \
        bash -euo pipefail -c 'set +h; source "$1"' fixture "$work/alignment.sh"
    ) >"$work/$name.log" 2>&1; then
      if [[ "$expected" == rejected ]] && grep -F 'Unsupported packageManager npm descriptor' "$work/$name.log" >/dev/null; then
        [[ ! -e "$prefix/lib/node_modules/npm" ]] || fail 'malformed contract installed npm'
        [[ "$(cat "$workspace/package.json")" == "$contract" ]] || fail "$name changed the consumer contract"
        echo "PASS: actual npm rejects $name before installation"
        return 0
      fi
      cat "$work/$name.log" >&2
      fail "actual npm replay failed: $name"
    fi
  fi
  [[ "$expected" != rejected ]] || fail 'malformed contract was accepted'
  version="$(env -i PATH="$prefix/bin:$base_path" npm_config_userconfig="$work/user.npmrc" npm_config_globalconfig="$work/global.npmrc" npm --version)"
  if [[ "$expected" == aligned ]]; then
    [[ "${version%%.*}" == 11 && -e "$prefix/lib/node_modules/npm/package.json" ]] || fail "$name did not activate npm 11"
  else
    [[ "$version" == "$base_version" && ! -e "$prefix/lib/node_modules/npm" ]] || fail "$name changed bundled npm"
  fi
  [[ "$(cat "$workspace/package.json")" == "$contract" ]] || fail "$name changed the consumer contract"
  echo "PASS: actual npm $name ($version)"
}
contract='{"devEngines":{"packageManager":{"name":"npm","version":"^11.0.0","onFail":"error"}}}'
run_case omitted '' "$contract" aligned
run_case explicit-true true "$contract" aligned
run_case explicit-false false "$contract" unchanged
run_case no-contract '' '{"name":"fixture"}' unchanged
run_case malformed '' '{"packageManager":"npm@11.2.0+unverified-integrity"}' rejected
[[ "$(npm --version)" == "$base_version" ]] || fail 'native replay modified the bundled npm'
echo 'PASS: real npm default and compatibility paths preserve bundled tooling and consumer files'
