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

# The one repository whose resource name and external name deliberately differ,
# as an adoption after a rename does. Its live fixture is named after the
# EXTERNAL name, so reading live state by the resource name finds nothing.
readonly RENAMED_RESOURCE="fixture-repo-7"
readonly RENAMED_EXTERNAL="fixture-repo-7-renamed"

# Builds a render + live pair that agree on every declared field; callers mutate
# one side afterwards to create the case under test.
#
# $2, when given, names the one repository whose DECLARED topics repeat an
# entry. Built in rather than patched in afterwards: an in-place yq edit of a
# multi-document render merges it into a single document and loses every
# repository but the last.
build_fixture() {
  local dir="$1" dup_topics_repo="${2:-}" i name external topics
  mkdir -p "$dir/live"
  : >"$dir/render.yaml"
  for ((i = 1; i <= FIXTURE_REPOS; i++)); do
    name="fixture-repo-$i"
    external="$name"
    [[ "$name" == "$RENAMED_RESOURCE" ]] && external="$RENAMED_EXTERNAL"
    topics='["beta", "alpha"]'
    [[ -n "$dup_topics_repo" && "$name" == "$dup_topics_repo" ]] && topics='["beta", "alpha", "beta"]'
    cat >>"$dir/render.yaml" <<EOF
---
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: Repository
metadata:
  name: $name
  annotations:
    crossplane.io/external-name: $external
spec:
  managementPolicies: [Observe, Create, Update]
  forProvider:
    name: $external
    description: "fixture $i"
    homepageUrl: "https://example.invalid/$i"
    visibility: public
    hasIssues: true
    allowSquashMerge: true
    allowMergeCommit: false
    webCommitSignoffRequired: true
    topics: $topics
EOF
    # Written in the REST object's own snake_case, by hand, so the mapping the
    # check derives has something independent to be wrong against. topics is
    # deliberately in the other order: the check compares it as a set.
    cat >"$dir/live/$external.json" <<EOF
{
  "name": "$external",
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
# Exactly one, so a check that flagged everything could not pass this either.
drift_lines="$(grep -c '^DRIFT ' "$work/drift/stdout" || true)"
[[ "$drift_lines" -eq 1 ]] ||
  fail "expected exactly one DRIFT line, got $drift_lines"

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

# --- 5. duplicate topics are a set, not a multiset ---------------------------
# A declaration that repeats a topic is untidy, but it is not a disagreement
# with live: GitHub cannot hold the duplicate, so reporting drift would name a
# divergence no change to the repository could ever close.
build_fixture "$work/topics-dupe" "fixture-repo-6"
expect_status "$work/topics-dupe" 0 "a duplicated declared topic"

# --- 6. live state is read by external name, not resource name ---------------
# The renamed fixture's live state is filed under its external name only, so a
# check keying on metadata.name cannot find it.
build_fixture "$work/renamed"
expect_status "$work/renamed" 0 "a resource whose external name differs"
[[ -f "$work/renamed/live/$RENAMED_EXTERNAL.json" && ! -f "$work/renamed/live/$RENAMED_RESOURCE.json" ]] ||
  fail "the renamed fixture must exist only under its external name"

# Drift on that repository is reported against the external name, and says which
# resource declared it.
build_fixture "$work/renamed-drift"
jq '.visibility = "private"' "$work/renamed-drift/live/$RENAMED_EXTERNAL.json" >"$work/renamed-drift/live/tmp.json"
mv "$work/renamed-drift/live/tmp.json" "$work/renamed-drift/live/$RENAMED_EXTERNAL.json"
expect_status "$work/renamed-drift" 1 "drift on a renamed repository"
grep -Fq "DRIFT $RENAMED_EXTERNAL.visibility [declared by $RENAMED_RESOURCE]" \
  "$work/renamed-drift/stdout" ||
  fail "drift on a renamed repository must name the repository and the declaring resource"

# --- 7. fail closed: a declared field with no live counterpart ---------------
# Skipping it would leave that setting permanently unchecked while the run still
# reported success.
build_fixture "$work/unmapped"
sed -i.bak 's/^    hasIssues: true$/    hasIssues: true\n    inventedSetting: true/' "$work/unmapped/render.yaml"
expect_status "$work/unmapped" 2 "a declared field absent from the live object"
grep -Fq 'inventedSetting but the live repository object has no "invented_setting" field' \
  "$work/unmapped/stderr" ||
  fail "the unmappable field must be named under both its declared and its mapped name"

# --- 8. fail closed: live state unavailable ----------------------------------
build_fixture "$work/missing"
rm "$work/missing/live/fixture-repo-4.json"
expect_status "$work/missing" 2 "unreadable live state"

# --- 9. fail closed: the render collapsed ------------------------------------
# An empty or truncated render must never read as "nothing drifted".
build_fixture "$work/collapsed"
yq -N -i 'select(.metadata.name == "fixture-repo-1")' "$work/collapsed/render.yaml"
expect_status "$work/collapsed" 2 "a collapsed render"
grep -Fq "collapsed to" "$work/collapsed/stderr" ||
  fail "a collapsed render must say so"

echo "repository-drift: OK — agreement, drift, set-compare, external-name and three fail-closed paths"
