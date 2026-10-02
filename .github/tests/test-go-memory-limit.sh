#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
yq -o=json '.' "$workflow" >"$work/workflow.json"
# shellcheck disable=SC2016 # Literal GitHub expressions are the source contract.
cat >"$work/contract.jq" <<'JQ'
 .on.workflow_call.inputs["go-memory-limit"].type == "string" and
 .on.workflow_call.inputs["go-memory-limit"].default == "8GiB" and
 (.concurrency.group | contains("inputs.go-memory-limit")) and
 ([.jobs | to_entries[] | select(.value.env.GOMEMLIMIT != null)] as $jobs |
  ($jobs | length) >= 2 and all($jobs[];
    .value.env.GOMEMLIMIT == "8GiB" and
    .value.env.GO_MEMORY_LIMIT == "${{ toJSON(inputs) == '{}' && '8GiB' || inputs.go-memory-limit }}" and
    (.value.steps as $steps |
      [$steps[] | select(.id == "memory-limit")] as $guard |
      ($guard | length) == 1 and $guard[0].shell == "bash" and
      ($guard[0] | has("if") or has("continue-on-error") | not) and
      ($guard[0].run | contains("validate-go-memory-limit.sh") and contains("$GO_MEMORY_LIMIT") and contains("$GITHUB_ENV")) and
      ([$steps[] | select(.with.path == ".devantler-tech-actions") |
        .with.repository == "${{ job.workflow_repository }}" and .with.ref == "${{ job.workflow_sha }}" and .with["persist-credentials"] == false] == [true]) and
      ([range(0; $steps|length) | select($steps[.].with.path == ".devantler-tech-actions")][0] <
       [range(0; $steps|length) | select($steps[.].id == "memory-limit")][0]) and
      all(range(0; $steps|length); . as $i |
        if (($steps[$i].uses // "" | startswith("actions/setup-go@")) or
           ($steps[$i].id // "") == "scan" or ($steps[$i].run // "" | test("(^|\\n) *go |deadcode -test")))
        then [range(0; $steps|length) | select($steps[.].id == "memory-limit")][0] < $i else true end))))
JQ
jq -e -f "$work/contract.jq" "$work/workflow.json" >/dev/null || fail 'Go memory override interface or preflight wiring'

# Exercise the shipped preflight and actual Go runtime, never a second parser.
cat >"$work/probe.go" <<'GO'
package main
import ("fmt"; "runtime/debug")
func main() { fmt.Print(debug.SetMemoryLimit(-1)) }
GO
go build -o "$work/probe" "$work/probe.go"
for job in deadcode govulncheck; do
  yq -r ".jobs.$job.steps[] | select(.id == \"memory-limit\") | .run" "$workflow" >"$work/preflight"
  mkdir -p "$work/workspace/.devantler-tech-actions/.github/scripts"
  cp "$root/.github/scripts/validate-go-memory-limit.sh" "$work/workspace/.devantler-tech-actions/.github/scripts/"
  for value in 4GiB 8GiB 08GiB 8589934592 8589934592B 8388608KiB 8192MiB 000000000000000000008GiB; do
    : >"$work/env"
    GO_MEMORY_LIMIT="$value" GITHUB_WORKSPACE="$work/workspace" GITHUB_ENV="$work/env" \
      bash -euo pipefail "$work/preflight" >"$work/output" 2>&1 || fail "$job rejected $value"
    [[ "$(cat "$work/env")" == "GOMEMLIMIT=$value" ]] || fail "$job did not export exactly the validated limit"
    expected=8589934592
    [[ "$value" != 4GiB ]] || expected=4294967296
    [[ "$(GOMEMLIMIT="$value" "$work/probe")" == "$expected" ]] || fail "$job disagrees with Go for $value"
  done
  for value in '' 12GB 8589934593B 9GiB 010GiB 1TiB 9999999999999999999 '8/0' $'4GiB\nINJECT=true'; do
    : >"$work/env"
    if GO_MEMORY_LIMIT="$value" GITHUB_WORKSPACE="$work/workspace" GITHUB_ENV="$work/env" \
      bash -euo pipefail "$work/preflight" >"$work/output" 2>&1; then fail "$job accepted unsafe input"; fi
    [[ ! -s "$work/env" ]] || fail "$job exported an invalid limit"
  done
done
echo 'PASS: memory override wiring, 16 native Go observations and 18 rejected invalid overrides'
