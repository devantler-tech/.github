#!/usr/bin/env bash
#
# Exercises scripts/check-repository-drift.sh against hand-written fixtures, so
# the comparison and the camelCase-to-snake_case field mapping are tested
# without touching the network.
#
# The cases that matter are the ones where a wrong answer is silent: a drift the
# check misses, and a field it cannot map reported as agreement.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo_root/scripts/check-repository-drift.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "repository-drift test: $*" >&2
  exit 1
}

# The check refuses to run on a render that yields fewer than ten repositories,
# so every fixture set has to clear that floor.
readonly FIXTURE_REPOS=10

# Builds a render + live pair that agree on every declared field. Callers mutate
# one of the two afterwards to create the case under test.
build_fixture() {
  local dir="$1" i name
  mkdir -p "$dir/live"
  : >"$dir/render.yaml"
  for ((i = 1; i <= FIXTURE_REPOS; i++)); do
    name="fixture-repo-$i"
    cat >>"$dir/render.yaml" <<EOF
---
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: Repository
metadata:
  name: $name
spec:
  managementPolicies: [Observe, Create, Update]
  forProvider:
    name: $name
    description: "fixture $i"
    homepageUrl: "https://example.invalid/$i"
    visibility: public
    hasIssues: true
    allowSquashMerge: true
    allowMergeCommit: false
    webCommitSignoffRequired: true
    topics: ["beta", "alpha"]
EOF
    # Written in the REST object's own snake_case, by hand, so the mapping the
    # check derives has something independent to be wrong against. topics is
    # deliberately in the other order: the check compares it as a set.
    cat >"$dir/live/$name.json" <<EOF
{
  "name": "$name",
  "description": "fixture $i",
  "homepage": "https://example.invalid/$i",
  "visibility": "public",
  "has_issues": true,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "web_commit_signoff_required": true,
  "topics": ["alpha", "beta"]
}
EOF
  done
}

run_check() {
  local dir="$1"
  REPOSITORY_DRIFT_RENDER="$dir/render.yaml" \
    REPOSITORY_DRIFT_LIVE_DIR="$dir/live" \
    bash "$check" >"$dir/stdout" 2>"$dir/stderr"
}

expect_status() {
  local dir="$1" want="$2" what="$3" got=0
  run_check "$dir" || got=$?
  [[ "$got" -eq "$want" ]] || {
    echo "repository-drift test: $what expected exit $want, got $got" >&2
    cat "$dir/stdout" "$dir/stderr" >&2
    exit 1
  }
}

# --- 1. agreement: every declared field matches live -------------------------
build_fixture "$work/clean"
expect_status "$work/clean" 0 "matching fixtures"
grep -Fq "repository-drift: OK" "$work/clean/stdout" ||
  fail "a clean run must say so on stdout"

# --- 2. drift: one declared field disagrees ----------------------------------
# visibility is the field devantler-tech/.github#123 was opened about: declared
# private, live public, and nothing surfaced it.
build_fixture "$work/drift"
jq '.visibility = "private"' "$work/drift/live/fixture-repo-3.json" >"$work/drift/live/fixture-repo-3.json.new"
mv "$work/drift/live/fixture-repo-3.json.new" "$work/drift/live/fixture-repo-3.json"
expect_status "$work/drift" 1 "a diverging field"
grep -Fq "DRIFT fixture-repo-3.visibility:" "$work/drift/stdout" ||
  fail "the drifting repository and field must be named on stdout"
grep -Fq "DRIFT fixture-repo-1." "$work/drift/stdout" &&
  fail "an agreeing repository must not be reported as drifting"

# --- 3. drift on a multi-word field, i.e. through the case mapping -----------
# A mapping bug would compare against a key the live object does not have, which
# case 4 pins as an abort; this pins that a correctly mapped field still
# compares by VALUE rather than being skipped.
build_fixture "$work/drift-snake"
jq '.web_commit_signoff_required = false' "$work/drift-snake/live/fixture-repo-5.json" >"$work/drift-snake/live/fixture-repo-5.json.new"
mv "$work/drift-snake/live/fixture-repo-5.json.new" "$work/drift-snake/live/fixture-repo-5.json"
expect_status "$work/drift-snake" 1 "a diverging multi-word field"
grep -Fq "DRIFT fixture-repo-5.webCommitSignoffRequired:" "$work/drift-snake/stdout" ||
  fail "a multi-word field must be reported under its declared name"

# --- 4. topics compare as a set, not as an ordered list ----------------------
build_fixture "$work/topics"
jq '.topics = ["beta", "alpha"]' "$work/topics/live/fixture-repo-2.json" >"$work/topics/live/fixture-repo-2.json.new"
mv "$work/topics/live/fixture-repo-2.json.new" "$work/topics/live/fixture-repo-2.json"
expect_status "$work/topics" 0 "topics in a different order"

build_fixture "$work/topics-drift"
jq '.topics = ["alpha"]' "$work/topics-drift/live/fixture-repo-2.json" >"$work/topics-drift/live/fixture-repo-2.json.new"
mv "$work/topics-drift/live/fixture-repo-2.json.new" "$work/topics-drift/live/fixture-repo-2.json"
expect_status "$work/topics-drift" 1 "a missing topic"

# --- 5. fail closed: a declared field with no live counterpart ---------------
# Skipping it would leave that setting permanently unchecked while the run still
# reported success.
build_fixture "$work/unmapped"
sed -i.bak 's/^    hasIssues: true$/    hasIssues: true\n    inventedSetting: true/' "$work/unmapped/render.yaml"
expect_status "$work/unmapped" 2 "a declared field absent from the live object"
grep -Fq "has no 'invented_setting' field" "$work/unmapped/stderr" ||
  fail "the unmappable field must be named"

# --- 6. fail closed: live state unavailable ----------------------------------
build_fixture "$work/missing"
rm "$work/missing/live/fixture-repo-4.json"
expect_status "$work/missing" 2 "unreadable live state"

# --- 7. fail closed: the render collapsed ------------------------------------
# An empty or truncated render must never read as "nothing drifted".
build_fixture "$work/collapsed"
yq -N -i 'select(.metadata.name == "fixture-repo-1")' "$work/collapsed/render.yaml"
expect_status "$work/collapsed" 2 "a collapsed render"
grep -Fq "collapsed to" "$work/collapsed/stderr" ||
  fail "a collapsed render must say so"

echo "repository-drift: OK — agreement, drift, set-compare and three fail-closed paths"
