#!/usr/bin/env bash
# The release workflow's catalogue CI projection must be production with only its display name
# changed and the release job's permissions emptied. Production's release job asks for
# id-token: write to reach the GitHub token broker; pull-request CI may not grant that
# (test-ci-idtoken-boundary.sh), and GitHub refuses a call whose caller grants less than a called
# job asks for, even when the job never runs. So catalogue CI calls the projection, which runs
# production's offline and egress jobs unchanged and can never reach the broker.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
production="${1:-$root/.github/workflows/create-release.yaml}"
projection="${2:-$root/.github/workflows/create-release-offline.yaml}"
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
  jq -S 'del(.name, .jobs.release.permissions)' "$1" >"$work/expected.json"
  jq -S 'del(.name, .jobs.release.permissions)' "$2" >"$work/actual.json"
  cmp -s "$work/expected.json" "$work/actual.json" ||
    { echo 'the release projection changed production behaviour; regenerate it'; return 1; }
  jq -e '.jobs.release.permissions == {"id-token":"write"}' "$1" >/dev/null ||
    { echo 'the production release job must ask for id-token: write and nothing else'; return 1; }
  jq -e '.name == "🎉 Create Release (Offline CI)" and .jobs.release.permissions == {} and
    ([.. | objects | select(has("id-token"))] | length) == 0' "$2" >/dev/null ||
    { echo 'the release projection must hold no id-token grant anywhere'; return 1; }
  jq -e '[.jobs | to_entries[] | select((.value.uses // "") | test("/\\.github/workflows/create-release(-offline)?\\.yaml"))] |
    (map(.key) | sort) == ["test-create-release", "test-create-release-no-issue-side-effects"] and
    all(.[]; .value.uses == "$/.github/workflows/create-release-offline.yaml" and
      (.value.permissions // {} | has("id-token") | not))' "$3" >/dev/null ||
    { echo 'catalogue CI must call the release workflow only through its broker-free projection'; return 1; }
}
result="$(check "$work/production.json" "$work/projection.json" "$work/ci.json")" || fail "$result"

bash "$root/.github/scripts/generate-create-release-offline.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/projection.json" >"$work/checked.json"
cmp -s "$work/generated.json" "$work/checked.json" || fail 'the release projection is stale; regenerate it'

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
projection	.jobs.release.permissions["id-token"]="write"	must hold no id-token grant anywhere
projection	.jobs["offline-test"].permissions["id-token"]="write"	changed production behaviour
projection	.jobs["offline-test"].steps += [{name:"extra", run:"echo unexpected"}]	changed production behaviour
projection	del(.jobs["egress-probe"])	changed production behaviour
projection	.permissions["id-token"]="write"	changed production behaviour
production	.jobs.release.permissions.contents="write"	must ask for id-token: write and nothing else
production	del(.jobs.release.permissions)	must ask for id-token: write and nothing else
ci	.jobs["test-create-release"].uses="$/.github/workflows/create-release.yaml"	only through its broker-free projection
ci	.jobs["test-create-release"].permissions["id-token"]="write"	only through its broker-free projection
ci	.jobs.extra={uses:"$/.github/workflows/create-release.yaml"}	only through its broker-free projection
CASES
echo "PASS: the release CI projection is production without its broker grant, and $count regressions are refused"
