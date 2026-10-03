#!/usr/bin/env bash
# Interpret the closed, literal vendor-output boundary as data for offline fixtures.
# This helper never executes code read from an action or workflow.
set -euo pipefail
action="${1:?action JSON required}"
fixture="${2:?fixture JSON required}"
jq -e '
  .inputs["exclude-vendored"].default == "false" and
  ([.runs.steps[] | select(.id == "vendored-ignore")] | length == 1 and
    all(.if == "${{ inputs.exclude-vendored == '\''true'\'' && inputs.ignore == '\'''\'' }}" and .shell == "bash")) and
  ([.runs.steps[] | select(.name == "📝 Create issues from TODOs")] | length == 1 and
    all(.env.INPUT_IGNORE == "${{ inputs.ignore || steps.vendored-ignore.outputs.ignore }}"))
' "$action" >/dev/null || { echo 'Invalid guarded vendor-filter boundary' >&2; exit 1; }
IFS= read -r expected <<'LITERAL'
printf 'ignore=^(vendor|third_party)/\n' >>"$GITHUB_OUTPUT"
LITERAL
actual="$(jq -er '.runs.steps[] | select(.id == "vendored-ignore") | .run' "$action")"
[[ "$actual" == "$expected" ]] || { echo 'Vendor output must remain a fixed literal' >&2; exit 1; }
ignore="$(jq -r --slurpfile action "$action" 'if has("Ignore") then .Ignore else $action[0].inputs.ignore.default end' "$fixture")"
flag="$(jq -r --slurpfile action "$action" 'if has("ExcludeVendored") then .ExcludeVendored else $action[0].inputs["exclude-vendored"].default end' "$fixture" | tr '[:upper:]' '[:lower:]')"
if [[ "$flag" == true && -z "$ignore" ]]; then ignore='^(vendor|third_party)/'; fi
printf '%s' "$ignore"
