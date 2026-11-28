#!/usr/bin/env bash
# The signed-fix workflow's catalogue CI projection must be production with only its display name
# changed and the apply-fixes job's id-token grant removed. Production asks for id-token: write to
# reach the GitHub token broker; pull-request CI may not grant that (test-ci-idtoken-boundary.sh),
# and GitHub refuses a call whose caller grants less than a called job asks for, even when the job
# never runs. So catalogue CI calls the projection, which runs production's steps unchanged and can
# never reach the broker.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
production="${1:-$root/.github/workflows/apply-signed-fixes.yaml}"
projection="${2:-$root/.github/workflows/apply-signed-fixes-ci.yaml}"
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
check() {
  jq -S 'del(.name, .jobs["apply-fixes"].permissions["id-token"])' "$1" >"$work/expected.json"
  jq -S 'del(.name, .jobs["apply-fixes"].permissions["id-token"])' "$2" >"$work/actual.json"
  cmp -s "$work/expected.json" "$work/actual.json" ||
    { echo 'the signed-fix projection changed production behaviour; regenerate it'; return 1; }
  jq -e '.jobs["apply-fixes"].permissions == {"contents":"read","id-token":"write"}' "$1" >/dev/null ||
    { echo 'the production apply-fixes job must ask for exactly contents read and id-token'; return 1; }
  jq -e --slurpfile p "$1" '.name == ($p[0].name + " (Broker-free CI)") and
    ([.. | objects | select(has("id-token"))] | length) == 0' "$2" >/dev/null ||
    { echo 'the signed-fix projection must hold no id-token grant anywhere'; return 1; }
  jq -e '[.jobs | to_entries[] | select((.value.uses // "") | test("/\\.github/workflows/apply-signed-fixes(-ci)?\\.yaml"))] |
    (map(.key) | sort) == ["test-apply-signed-fixes-suppresses-bots", "test-apply-signed-fixes-verifies-without-a-patch"] and
    all(.[]; .value.uses == "$/.github/workflows/apply-signed-fixes-ci.yaml" and (.value.permissions // {} | has("id-token") | not))' "$3" >/dev/null ||
    { echo 'catalogue CI must call the signed-fix workflow only through its broker-free projection'; return 1; }
}
result="$(check "$work/production.json" "$work/projection.json" "$work/ci.json")" || fail "$result"
bash "$root/.github/scripts/generate-apply-signed-fixes-ci.sh" "$production" "$work/generated.yaml"
cmp -s <(yq -o=json '.' "$work/generated.yaml" | jq -S '.') <(jq -S '.' "$work/projection.json") || fail 'the signed-fix projection is stale; regenerate it'
count=0
while IFS=$'\t' read -r scope mutation diagnostic; do
  for f in production projection ci; do cp "$work/$f.json" "$work/m-$f.json"; done
  jq "$mutation" "$work/$scope.json" >"$work/m-$scope.json"
  jq -e --slurp ".[0] != .[1]" "$work/$scope.json" "$work/m-$scope.json" >/dev/null || fail "mutation changed nothing: $mutation"
  if result="$(check "$work/m-production.json" "$work/m-projection.json" "$work/m-ci.json")"; then fail "accepted: $mutation"; fi
  grep -qF "$diagnostic" <<<"$result" || fail "wrong reason for $mutation: $result"
  count=$((count + 1))
done <<'CASES'
projection	.jobs["apply-fixes"].permissions["id-token"]="write"	must hold no id-token grant anywhere
projection	.jobs["apply-fixes"].steps += [{name:"extra", run:"echo unexpected"}]	changed production behaviour
projection	.jobs["apply-fixes"].if="true"	changed production behaviour
production	.jobs["apply-fixes"].permissions.contents="write"	changed production behaviour
production	del(.jobs["apply-fixes"].permissions["id-token"])	exactly contents read and id-token
ci	.jobs["test-apply-signed-fixes-suppresses-bots"].uses="$/.github/workflows/apply-signed-fixes.yaml"	only through its broker-free projection
ci	.jobs["test-apply-signed-fixes-suppresses-bots"].permissions["id-token"]="write"	only through its broker-free projection
ci	.jobs.extra={uses:"$/.github/workflows/apply-signed-fixes.yaml"}	only through its broker-free projection
CASES
echo "PASS: the signed-fix CI projection is production without its broker grant, and $count regressions are refused"
