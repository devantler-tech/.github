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
# entry; $3 the one whose live state is private. Built in rather than patched in
# afterwards: an in-place yq edit of a multi-document render merges it into a
# single document and loses every repository but the last.
build_fixture() {
  local dir="$1" dup_topics_repo="${2:-}" private_repo="${3:-}" i name external topics is_private
  mkdir -p "$dir/live"
  : >"$dir/render.yaml"
  for ((i = 1; i <= FIXTURE_REPOS; i++)); do
    name="fixture-repo-$i"
    external="$name"
    [[ "$name" == "$RENAMED_RESOURCE" ]] && external="$RENAMED_EXTERNAL"
    topics='["beta", "alpha"]'
    is_private=false
    [[ -n "$private_repo" && "$name" == "$private_repo" ]] && is_private=true
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
  "private": $is_private,
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

# --- 7. a private repository's values are withheld from the output -----------
# This repository is public, so its Actions logs are public. A finding on a
# private repository must name the field and print neither value.
build_fixture "$work/private" "" "fixture-repo-4"
jq '.description = "an internal description that must not be printed"' \
  "$work/private/live/fixture-repo-4.json" >"$work/private/live/tmp.json"
mv "$work/private/live/tmp.json" "$work/private/live/fixture-repo-4.json"
expect_status "$work/private" 1 "drift on a private repository"
grep -Fq "DRIFT fixture-repo-4.description: values withheld — private repository" \
  "$work/private/stdout" ||
  fail "a private repository's finding must name the field and withhold the values"
if grep -Fq "an internal description that must not be printed" "$work/private/stdout" "$work/private/stderr"; then
  fail "a private repository's live value leaked into the output"
fi

# A public repository is unaffected — the values are what make a finding useful.
build_fixture "$work/public-values"
jq '.description = "a public description that should be printed"' \
  "$work/public-values/live/fixture-repo-4.json" >"$work/public-values/live/tmp.json"
mv "$work/public-values/live/tmp.json" "$work/public-values/live/fixture-repo-4.json"
expect_status "$work/public-values" 1 "drift on a public repository"
grep -Fq "a public description that should be printed" "$work/public-values/stdout" ||
  fail "a public repository's values must still be reported"

# --- 8. fail closed: live state whose visibility cannot be determined --------
build_fixture "$work/no-private-flag"
jq 'del(.private)' "$work/no-private-flag/live/fixture-repo-2.json" >"$work/no-private-flag/live/tmp.json"
mv "$work/no-private-flag/live/tmp.json" "$work/no-private-flag/live/fixture-repo-2.json"
expect_status "$work/no-private-flag" 2 "live state with no private flag"
grep -Fq "has no 'private' flag" "$work/no-private-flag/stderr" ||
  fail "the missing visibility flag must be named"

# --- 9. fail closed: a declared field with no live counterpart ---------------
# Skipping it would leave that setting permanently unchecked while the run still
# reported success.
build_fixture "$work/unmapped"
sed -i.bak 's/^    hasIssues: true$/    hasIssues: true\n    inventedSetting: true/' "$work/unmapped/render.yaml"
expect_status "$work/unmapped" 2 "a declared field absent from the live object"
grep -Fq 'inventedSetting but the live repository object has no "invented_setting" field' \
  "$work/unmapped/stderr" ||
  fail "the unmappable field must be named under both its declared and its mapped name"

# --- 10. fail closed: live state unavailable ----------------------------------
build_fixture "$work/missing"
rm "$work/missing/live/fixture-repo-4.json"
expect_status "$work/missing" 2 "unreadable live state"

# --- 11. fail closed: the render collapsed ------------------------------------
# An empty or truncated render must never read as "nothing drifted".
build_fixture "$work/collapsed"
yq -N -i 'select(.metadata.name == "fixture-repo-1")' "$work/collapsed/render.yaml"
expect_status "$work/collapsed" 2 "a collapsed render"
grep -Fq "collapsed to" "$work/collapsed/stderr" ||
  fail "a collapsed render must say so"

# Exercise the real gh transport path, including the REST omissions observed
# with an installation token. The fake accepts only the expected read requests.
transport="$work/transport"
build_fixture "$transport"
mkdir -p "$transport/bin" "$transport/graphql"
yq '.spec.forProvider *= {"allowAutoMerge": true, "allowRebaseMerge": false, "allowUpdateBranch": true, "deleteBranchOnMerge": true}' \
  "$transport/render.yaml" >"$transport/render.new"
mv "$transport/render.new" "$transport/render.yaml"
for file in "$transport"/live/*.json; do
  jq '. + {node_id: ("R_" + .name), full_name: ("devantler-tech/" + .name),
    allow_auto_merge: true, allow_rebase_merge: false, allow_update_branch: true,
    delete_branch_on_merge: true}' "$file" >"$file.new"
  mv "$file.new" "$file"
  jq '{data: {repository: {
    id: .node_id, nameWithOwner: .full_name, isPrivate: .private,
    allow_auto_merge, allow_squash_merge, allow_merge_commit, allow_rebase_merge,
    allow_update_branch, delete_branch_on_merge, web_commit_signoff_required
  }}}' "$file" >"$transport/graphql/$(basename "$file")"
done
cat >"$transport/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == api ]] || exit 91
if [[ "$2" == graphql ]]; then
  shift 2
  owner="" name="" query=""
  while [[ "$#" -gt 0 ]]; do
    [[ "$1" == -f || "$1" == -F ]] || exit 92
    case "$2" in
      owner=*) owner="${2#owner=}" ;;
      name=*) name="${2#name=}" ;;
      query=*) query="${2#query=}" ;;
      *) exit 93 ;;
    esac
    shift 2
  done
  [[ "$owner" == devantler-tech && "$name" == fixture-repo-* ]] || exit 94
  for field in autoMergeAllowed squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed \
    allowUpdateBranch deleteBranchOnMerge webCommitSignoffRequired nameWithOwner isPrivate; do
    [[ "$query" == *"$field"* ]] || exit 95
  done
  echo "$name" >>"$DRIFT_GH_FIXTURES/graphql-calls"
  [[ ! -e "$DRIFT_GH_FIXTURES/graphql-error" ]] || exit 96
  cat "$DRIFT_GH_FIXTURES/graphql/$name.json"
else
  [[ "$#" == 2 && "$2" == repos/devantler-tech/fixture-repo-* ]] || exit 97
  cat "$DRIFT_GH_FIXTURES/live/${2##*/}.json"
fi
EOF
chmod +x "$transport/bin/gh"

expect_transport_status() {
  local dir="$1" want="$2" what="$3" got=0
  PATH="$dir/bin:$PATH" DRIFT_GH_FIXTURES="$dir" \
    REPOSITORY_DRIFT_OWNER=devantler-tech \
    REPOSITORY_DRIFT_RENDER="$dir/render.yaml" REPOSITORY_DRIFT_LIVE_DIR= \
    bash "$check" >"$dir/stdout" 2>"$dir/stderr" || got=$?
  [[ "$got" -eq "$want" ]] || {
    cat "$dir/stdout" "$dir/stderr" >&2
    fail "$what expected exit $want, got $got"
  }
}

expect_transport_status "$transport" 0 "complete REST response"
[[ ! -e "$transport/graphql-calls" ]] || fail "complete REST data must not query GraphQL"

missing_settings="$work/missing-settings"
cp -R "$transport" "$missing_settings"
for file in "$missing_settings"/live/*.json; do
  jq 'del(.allow_auto_merge, .allow_squash_merge, .allow_merge_commit,
    .allow_rebase_merge, .allow_update_branch, .delete_branch_on_merge,
    .web_commit_signoff_required)' "$file" >"$file.new"
  mv "$file.new" "$file"
done
expect_transport_status "$missing_settings" 0 "REST omits settings, GraphQL supplies them"
[[ "$(wc -l <"$missing_settings/graphql-calls" | tr -d ' ')" == "$FIXTURE_REPOS" ]] ||
  fail "every incomplete REST response must get one scoped GraphQL read"
grep -Fxq "$RENAMED_EXTERNAL" "$missing_settings/graphql-calls" ||
  fail "GraphQL lookup must use the declared external repository name"

# Every mapped field must still detect a real divergence, including false values.
for pair in allow_auto_merge:allowAutoMerge allow_squash_merge:allowSquashMerge \
  allow_merge_commit:allowMergeCommit allow_rebase_merge:allowRebaseMerge \
  allow_update_branch:allowUpdateBranch delete_branch_on_merge:deleteBranchOnMerge \
  web_commit_signoff_required:webCommitSignoffRequired; do
  dir="$work/graphql-drift-${pair%%:*}"
  cp -R "$missing_settings" "$dir"
  jq --arg field "${pair%%:*}" '.data.repository[$field] |= not' \
    "$dir/graphql/fixture-repo-1.json" >"$dir/changed.json"
  mv "$dir/changed.json" "$dir/graphql/fixture-repo-1.json"
  expect_transport_status "$dir" 1 "GraphQL drift in ${pair%%:*}"
  grep -Fq "DRIFT fixture-repo-1.${pair#*:}:" "$dir/stdout" ||
    fail "GraphQL drift must name the mapped declared field"
done

dir="$work/rest-false-wins"
cp -R "$missing_settings" "$dir"
jq '.allow_merge_commit = false' "$dir/live/fixture-repo-1.json" >"$dir/changed.json"
mv "$dir/changed.json" "$dir/live/fixture-repo-1.json"
jq '.data.repository.allow_merge_commit = true' "$dir/graphql/fixture-repo-1.json" >"$dir/changed.json"
mv "$dir/changed.json" "$dir/graphql/fixture-repo-1.json"
expect_transport_status "$dir" 0 "present false REST setting wins over GraphQL"

for invalid in wrong-id wrong-name changed-privacy null-repository partial-error false-errors \
  missing-boolean null-boolean string-boolean malformed-json transport-error; do
  dir="$work/graphql-$invalid"
  cp -R "$missing_settings" "$dir"
  file="$dir/graphql/fixture-repo-1.json"
  case "$invalid" in
    wrong-id) filter='.data.repository.id = "R_different"' ;;
    wrong-name) filter='.data.repository.nameWithOwner = "another/repository"' ;;
    changed-privacy) filter='.data.repository.isPrivate = true' ;;
    null-repository) filter='.data.repository = null' ;;
    partial-error) filter='.errors = [{message: "partial response"}]' ;;
    false-errors) filter='.errors = false' ;;
    missing-boolean) filter='del(.data.repository.allow_auto_merge)' ;;
    null-boolean) filter='.data.repository.allow_auto_merge = null' ;;
    string-boolean) filter='.data.repository.allow_auto_merge = "true"' ;;
    malformed-json) printf '{' >"$file"; filter='' ;;
    transport-error) touch "$dir/graphql-error"; filter='' ;;
  esac
  if [[ -n "$filter" ]]; then
    jq "$filter" "$file" >"$dir/changed.json"
    mv "$dir/changed.json" "$file"
  fi
  expect_transport_status "$dir" 2 "invalid GraphQL response: $invalid"
done

for invalid in missing-id missing-name null-setting string-setting null-privacy string-privacy; do
  dir="$work/rest-$invalid"
  cp -R "$missing_settings" "$dir"
  case "$invalid" in
    missing-id) filter='del(.node_id)' ;;
    missing-name) filter='del(.full_name)' ;;
    null-setting) filter='.allow_merge_commit = null' ;;
    string-setting) filter='.allow_merge_commit = "false"' ;;
    null-privacy) filter='.private = null' ;;
    string-privacy) filter='.private = "false"' ;;
  esac
  jq "$filter" "$dir/live/fixture-repo-1.json" >"$dir/changed.json"
  mv "$dir/changed.json" "$dir/live/fixture-repo-1.json"
  expect_transport_status "$dir" 2 "invalid REST response: $invalid"
done

dir="$work/rest-complete-invalid-privacy"
cp -R "$transport" "$dir"
jq '.private = "false" | .description = "sensitive live description"' \
  "$dir/live/fixture-repo-1.json" >"$dir/changed.json"
mv "$dir/changed.json" "$dir/live/fixture-repo-1.json"
expect_transport_status "$dir" 2 "complete REST response with malformed visibility"
! grep -Fq 'sensitive live description' "$dir/stdout" "$dir/stderr" ||
  fail "malformed visibility must not disclose live values"

dir="$work/graphql-private-drift"
cp -R "$missing_settings" "$dir"
jq '.private = true | .description = "sensitive live description"' \
  "$dir/live/fixture-repo-1.json" >"$dir/changed.json"
mv "$dir/changed.json" "$dir/live/fixture-repo-1.json"
jq '.data.repository.isPrivate = true | .data.repository.allow_auto_merge = false' \
  "$dir/graphql/fixture-repo-1.json" >"$dir/changed.json"
mv "$dir/changed.json" "$dir/graphql/fixture-repo-1.json"
expect_transport_status "$dir" 1 "private drift after GraphQL completion"
grep -Fq 'DRIFT fixture-repo-1.allowAutoMerge: values withheld' "$dir/stdout" ||
  fail "GraphQL completion must retain private-repository redaction"
! grep -Fq 'sensitive live description' "$dir/stdout" "$dir/stderr" ||
  fail "GraphQL completion must not disclose private live values"

# Unknown declarations must still fail closed after known settings are filled.
dir="$work/graphql-unmapped"
cp -R "$missing_settings" "$dir"
yq '.spec.forProvider.inventedSetting = true' "$dir/render.yaml" >"$dir/render.new"
mv "$dir/render.new" "$dir/render.yaml"
expect_transport_status "$dir" 2 "unmapped declaration after GraphQL read"
grep -Fq 'inventedSetting but the live repository object has no "invented_setting" field' "$dir/stderr" ||
  fail "GraphQL completion must not hide unrelated missing fields"

echo "repository-drift: OK — comparison, private redaction, REST/GraphQL settings and fail-closed reads"
