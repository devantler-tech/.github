#!/usr/bin/env bash
# Only bounded scheduling metadata crosses from the consumer into Go arguments.
set -euo pipefail
export LC_ALL=C GIT_NO_REPLACE_OBJECTS=1
fail() {
  printf '::error::Go test parallelism: %s\n' "$1" >&2
  exit 2
}
direct="${DIRECT_REQUIRED_RUN:-false}"
opted_in="${TEST_PARALLELISM_OPT_IN:-false}"
[[ "$direct" == true || "$direct" == false ]] || fail 'invalid invocation identity'
[[ "$opted_in" == true || "$opted_in" == false ]] || fail 'invalid opt-in'
if [[ "$direct" == false ]]; then
  [[ "$opted_in" == true ]] || exit 0
  value="${TEST_PARALLELISM_INPUT:-}"
  [[ "$value" =~ ^[1-8]$ ]] || fail 'called parallelism must be an integer from one to eight'
  printf '%s\n' "$value"
  exit 0
fi

[[ -n "${GITHUB_WORKSPACE:-}" ]] || fail 'missing workspace'
cd -- "$GITHUB_WORKSPACE"
workspace="$(pwd -P)"
[[ "$(git rev-parse --show-toplevel)" == "$workspace" ]] || fail 'workspace is not the checkout root'
module="${MODULE_DIRECTORY:-.}"
[[ "$module" == '.' || "$module" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
  fail 'unsafe module directory'
current="$workspace"
if [[ "$module" != '.' ]]; then
  IFS=/ read -r -a components <<<"$module"
  for component in "${components[@]}"; do
    [[ "$component" != '.' && "$component" != '..' ]] || fail 'module path contains traversal'
    current="$current/$component"
    [[ -d "$current" && ! -L "$current" ]] || fail 'module directory is missing or linked'
  done
  file="$module/.go-test-execution.json"
else
  file=.go-test-execution.json
fi
entry="$(git ls-tree HEAD -- "$file")" || fail 'cannot read committed declaration identity'
if [[ -z "$entry" ]]; then
  [[ ! -e "$file" && ! -L "$file" ]] || fail 'declaration is not committed'
  exit 0
fi
[[ "$entry" == *$'\t'* ]] || fail 'invalid declaration identity'
metadata="${entry%%$'\t'*}"
[[ "$metadata" =~ ^100(644|755)\ blob\ ([0-9a-f]{40}|[0-9a-f]{64})$ ]] ||
  fail 'declaration is not a committed regular file'
expected="${BASH_REMATCH[2]}"
[[ -f "$file" && ! -L "$file" ]] || fail 'declaration is missing or linked'
[[ "$(git hash-object --no-filters -- "$file")" == "$expected" ]] ||
  fail 'declaration differs from the committed revision'
size="$(wc -c <"$file")"
[[ "$size" -le 1024 ]] || fail 'declaration exceeds the closed schema size'
# Stream entries preserve duplicate keys, unlike an ordinary JSON object parse.
value="$(jq --stream -ser '
  [.[] | select(length == 2)] as $entries
  | if ($entries | map(.[0]) | sort) != [["parallelism"], ["version"]]
    then error("expected only version and parallelism, each once") else . end
  | reduce $entries[] as $entry ({}; .[$entry[0][0]] = $entry[1])
  | if .version != 1 then error("unsupported version") else . end
  | .parallelism
  | if type != "number" then error("parallelism must be numeric") else . end
  | if . != floor or . < 1 or . > 8 then error("parallelism is outside one to eight") else floor end
' "$file")" || fail 'invalid declaration'
[[ "$value" =~ ^[1-8]$ ]] || fail 'invalid resolved parallelism'
printf '%s\n' "$value"
