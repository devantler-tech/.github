#!/usr/bin/env bash
# A missing job deadline lets stalled runner setup occupy required CI for six hours.
set -euo pipefail

workflow=${1:-.github/workflows/ci.yaml}
[[ $# -le 1 && -f "$workflow" ]] || {
  echo 'ci runner deadlines: expected one existing workflow' >&2
  exit 1
}

jobs=$(yq -o=json '.jobs' "$workflow") || {
  echo 'ci runner deadlines: cannot parse workflow jobs' >&2
  exit 1
}
jq -e 'type == "object" and length > 0 and all(.[]; type == "object")' \
  <<<"$jobs" >/dev/null || {
  echo 'ci runner deadlines: expected a nonempty job mapping' >&2
  exit 1
}

# GitHub rejects timeout-minutes on reusable-call jobs. Only the callee can bound
# its runners; that separate adoption remains on #749, not this direct-job guard.
invalid=$(jq -r '
  to_entries[]
  | select(
      if .value | has("uses") then
        ((.value.uses | type) != "string") or (.value.uses == "")
        or (.value | has("steps") or has("runs-on") or has("timeout-minutes"))
      else
        ((.value.steps | type) != "array") or (.value.steps | length == 0)
        or ((.value["timeout-minutes"] | type) != "number")
        or ((.value["timeout-minutes"] // 0) < 1)
        or ((.value["timeout-minutes"] // 0) > 15)
        or ((.value["timeout-minutes"] // 0) != ((.value["timeout-minutes"] // 0) | floor))
      end)
  | .key' <<<"$jobs") || {
  echo 'ci runner deadlines: cannot validate job limits' >&2
  exit 1
}
if [[ -n "$invalid" ]]; then
  printf 'ci runner deadlines: invalid direct job deadline or reusable call:\n%s\n' "$invalid" >&2
  exit 1
fi
echo 'ci runner deadlines: all direct runners have finite 1–15 minute limits; reusable calls retain callee ownership'
