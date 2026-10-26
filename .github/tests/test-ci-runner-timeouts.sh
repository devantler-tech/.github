#!/usr/bin/env bash
# A missing job deadline lets stalled runner setup occupy required CI for six hours.
set -euo pipefail

if [[ ${1:-} == --callees ]]; then
  [[ $# == 2 && -d "$2" && ! -L "$2" ]] || {
    echo 'ci runner deadlines: expected a workflow directory' >&2
    exit 1
  }
  count=0
  for file in "$2/"*.yaml "$2/"*.yml; do
    [[ ! -L "$file" ]] || {
      echo 'ci runner deadlines: expected a regular workflow' >&2
      exit 1
    }
    [[ -e "$file" ]] || continue
    callable=$(yq -o=json '.on' "$file" | jq -r '
      if type == "object" then has("workflow_call")
      elif type == "string" then . == "workflow_call"
      elif type == "array" and all(.[]; type == "string") then index("workflow_call") != null
      else error("cannot classify workflow triggers") end') || {
      echo 'ci runner deadlines: cannot classify workflow triggers' >&2
      exit 1
    }
    if [[ "$callable" == true ]]; then
      bash "$0" --callee "$file"
      count=$((count + 1))
    fi
  done
  [[ "$count" -gt 0 ]] || {
    echo 'ci runner deadlines: no callable workflows examined' >&2
    exit 1
  }
  printf 'ci runner deadlines: examined %s local callable workflows; remote revisions require independent adoption\n' "$count"
  exit 0
fi

maximum=15
if [[ ${1:-} == --callee ]]; then
  [[ $# == 2 ]] || {
    echo 'ci runner deadlines: expected one existing workflow' >&2
    exit 1
  }
  maximum=60
  shift
fi
workflow=${1:-.github/workflows/ci.yaml}
[[ $# -le 1 && -f "$workflow" ]] || {
  echo 'ci runner deadlines: expected one existing workflow' >&2
  exit 1
}
[[ ! -L "$workflow" ]] || {
  echo 'ci runner deadlines: expected a regular workflow' >&2
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

# GitHub rejects timeout-minutes on reusable-call jobs. Inspect local callee
# implementations separately; this does not validate a remote pinned revision.
invalid=$(jq -r --argjson maximum "$maximum" '
  to_entries[]
  | select(
      if .value | has("uses") then
        ((.value.uses | type) != "string") or (.value.uses == "")
        or (.value | has("steps") or has("runs-on") or has("timeout-minutes"))
      else
        ((.value.steps | type) != "array") or (.value.steps | length == 0)
        or ((.value["timeout-minutes"] | type) != "number")
        or ((.value["timeout-minutes"] // 0) < 1)
        or ((.value["timeout-minutes"] // 0) > $maximum)
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
printf 'ci runner deadlines: %s runners have finite 1–%s minute limits; reusable calls retain callee ownership\n' "$workflow" "$maximum"
