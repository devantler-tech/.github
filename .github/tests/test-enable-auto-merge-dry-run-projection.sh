#!/usr/bin/env bash
# The auto-merge workflow's catalogue CI projection must be production with only its display name
# changed, its triggers reduced to workflow_call, and the auto-merge job's id-token grant removed.
# Production's auto-merge job asks for id-token: write to reach the GitHub token broker; pull-request
# CI may not grant that (test-ci-idtoken-boundary.sh), and GitHub refuses a call whose caller grants
# less than a called job asks for, even when the job never runs. So catalogue CI calls the
# projection, which runs production's dry-run job unchanged, never triggers on its own, and can
# never reach the broker.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
production="${1:-$root/.github/workflows/enable-auto-merge.yaml}"
projection="${2:-$root/.github/workflows/enable-auto-merge-dry-run.yaml}"
ci="${3:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
yq -o=json '.' "$production" >"$work/production.json"
yq -o=json '.' "$projection" >"$work/projection.json"
yq -o=json '.' "$ci" >"$work/ci.json"

# check <production.json> <projection.json> <ci.json>: every boundary, independent of the generator.
check() {
  jq -S 'del(.name, .on, .jobs["auto-merge"].permissions["id-token"])' "$1" >"$work/expected.json"
  jq -S 'del(.name, .on, .jobs["auto-merge"].permissions["id-token"])' "$2" >"$work/actual.json"
  cmp -s "$work/expected.json" "$work/actual.json" ||
    { echo 'the auto-merge projection changed production behaviour; regenerate it'; return 1; }
  jq -e --slurpfile p "$1" '.on == {workflow_call: $p[0].on.workflow_call}' "$2" >/dev/null ||
    { echo 'the auto-merge projection must keep exactly production workflow_call trigger and no other'; return 1; }
  jq -e '.jobs["auto-merge"].permissions == {"pull-requests":"write","contents":"write","id-token":"write"}' "$1" >/dev/null ||
    { echo 'the production auto-merge job must ask for exactly contents, pull-requests and id-token'; return 1; }
  jq -e '.name == "🔀 Enable Auto-Merge (Dry-Run CI)" and
    ([.. | objects | select(has("id-token"))] | length) == 0' "$2" >/dev/null ||
    { echo 'the auto-merge projection must hold no id-token grant anywhere'; return 1; }
  jq -e '[.jobs | to_entries[] | select((.value.uses // "") | test("/\\.github/workflows/enable-auto-merge(-dry-run)?\\.yaml"))] |
    (map(.key) | sort) == ["test-enable-auto-merge", "test-enable-auto-merge-actor-trust", "test-enable-auto-merge-queued"] and
    all(.[]; .value.uses == "$/.github/workflows/enable-auto-merge-dry-run.yaml" and
      .value.with["dry-run"] == true and (.value.permissions // {} | has("id-token") | not))' "$3" >/dev/null ||
    { echo 'catalogue CI must call the auto-merge workflow only through its broker-free projection, in dry-run'; return 1; }
}
result="$(check "$work/production.json" "$work/projection.json" "$work/ci.json")" || fail "$result"

bash "$root/.github/scripts/generate-enable-auto-merge-dry-run.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/projection.json" >"$work/checked.json"
cmp -s "$work/generated.json" "$work/checked.json" || fail 'the auto-merge projection is stale; regenerate it'

count=0
while IFS=$'\t' read -r scope mutation diagnostic; do
  for f in production projection ci; do cp "$work/$f.json" "$work/m-$f.json"; done
  jq "$mutation" "$work/$scope.json" >"$work/m-$scope.json"
  jq -e --slurp ".[0] != .[1]" "$work/$scope.json" "$work/m-$scope.json" >/dev/null || fail "mutation changed nothing: $mutation"
  if result="$(check "$work/m-production.json" "$work/m-projection.json" "$work/m-ci.json")"; then
    fail "accepted: $mutation"
  fi
  grep -qF "$diagnostic" <<<"$result" || fail "wrong reason for $mutation: $result"
  count=$((count + 1))
done <<'CASES'
projection	.jobs["auto-merge"].permissions["id-token"]="write"	must hold no id-token grant anywhere
projection	.jobs["dry-run"].permissions["id-token"]="write"	changed production behaviour
projection	.on.pull_request={}	must keep exactly production workflow_call trigger
projection	.on.issue_comment={types:["created"]}	must keep exactly production workflow_call trigger
projection	.jobs["dry-run"].steps += [{name:"extra", run:"echo unexpected"}]	changed production behaviour
projection	del(.jobs.eligibility)	changed production behaviour
production	.jobs["auto-merge"].permissions.actions="write"	changed production behaviour
production	del(.jobs["auto-merge"].permissions["id-token"])	exactly contents, pull-requests and id-token
ci	.jobs["test-enable-auto-merge"].uses="$/.github/workflows/enable-auto-merge.yaml"	only through its broker-free projection
ci	.jobs["test-enable-auto-merge"].permissions["id-token"]="write"	only through its broker-free projection
ci	.jobs["test-enable-auto-merge-queued"].with["dry-run"]=false	only through its broker-free projection
ci	.jobs.extra={uses:"$/.github/workflows/enable-auto-merge.yaml"}	only through its broker-free projection
CASES
echo "PASS: the auto-merge CI projection is production without its broker grant or triggers, and $count regressions are refused"
