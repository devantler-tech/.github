#!/usr/bin/env bash
# Exercise the real caller guard with independent local Git histories.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
guard="$root/.github/scripts/check-manifests-caller.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: manifests caller fixture: $*" >&2
  exit 1
}
fixture_git() {
  git -C "$work/source" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c gc.auto=0 -c maintenance.auto=false "$@"
}
git init --quiet "$work/source"
mkdir -p "$work/source/.github/workflows" "$work/source/.github/scripts"
workflow='.github/workflows/publish-manifests.yaml'
absence='.github/scripts/require-unpublished-version.sh'
recovery='.github/scripts/recover-manifests-version.sh'
for path in "$workflow" "$absence" "$recovery"; do
  printf 'independently reviewed fixture: %s\n' "$path" >"$work/source/$path"
  fixture_git add -- "$path"
done
fixture_git commit --quiet -m reviewed
reviewed="$(fixture_git rev-parse HEAD)"
workflow_blob="$(fixture_git rev-parse "HEAD:$workflow")"
absence_blob="$(fixture_git rev-parse "HEAD:$absence")"
recovery_blob="$(fixture_git rev-parse "HEAD:$recovery")"
printf 'unrelated release\n' >"$work/source/RELEASE"
fixture_git add -- RELEASE
fixture_git commit --quiet -m release
release="$(fixture_git rev-parse HEAD)"
for path in "$workflow" "$absence" "$recovery"; do
  printf 'unreviewed change\n' >>"$work/source/$path"
  fixture_git add -- "$path"
  fixture_git commit --quiet -m changed
  case "$path" in
    "$workflow") changed_workflow="$(fixture_git rev-parse HEAD)" ;;
    "$absence") changed_absence="$(fixture_git rev-parse HEAD)" ;;
    "$recovery") changed_recovery="$(fixture_git rev-parse HEAD)" ;;
  esac
  fixture_git checkout --quiet "$release" -- "$path"
  fixture_git commit --quiet -m restore
done
fixture_git update-index --chmod=+x "$workflow"
fixture_git commit --quiet -m mode
changed_mode="$(fixture_git rev-parse HEAD)"
fixture_git config uploadpack.allowFilter true
fixture_git config uploadpack.allowAnySHA1InWant true
make_guard() {
  sed -e "s|^reviewed_workflow_blob='.*'$|reviewed_workflow_blob='$workflow_blob'|" \
    -e "s|^approved_publisher_revision='.*'$|approved_publisher_revision='$reviewed'|" \
    -e "s|^reviewed_absence_blob='.*'$|reviewed_absence_blob='$absence_blob'|" \
    -e "s|^reviewed_recovery_blob='.*'$|reviewed_recovery_blob='$recovery_blob'|" \
    -e "s|^source_remote='.*'$|source_remote='$1'|" "$guard" >"$2"
}
make_guard "$work/unavailable" "$work/offline.sh"
make_guard "file://$work/source" "$work/fetching.sh"
yq -o=json '.' "$root/.github/workflows/cd.yaml" >"$work/baseline.json"
prefix='devantler-tech/.github/.github/workflows/publish-manifests.yaml'
mutate() {
  jq --arg prefix "$prefix" --arg reviewed "$reviewed" --arg release "$release" \
    --arg workflow "$changed_workflow" --arg absence "$changed_absence" \
    --arg recovery "$changed_recovery" --arg mode "$changed_mode" \
    '.jobs["publish-manifests"].uses = ($prefix + "@" + $reviewed) | '"$1" \
    "$work/baseline.json" >"$work/caller.json"
}
run_guard() { (
  cd "$2"
  bash "$1" "$work/caller.json"
); }
mutate '.'
run_guard "$work/offline.sh" "$work/source" >"$work/result" 2>&1 || {
  cat "$work/result" >&2
  fail 'rejected approved publisher'
}
# The two commits carry byte-identical publishers but different signer identities.
# An unrelated release must not become an approved signer implicitly.
# shellcheck disable=SC2016 # jq variables, not shell expansion.
mutate '.jobs["publish-manifests"].uses = ($prefix + "@" + $release)'
if run_guard "$work/offline.sh" "$work/source" >"$work/result" 2>&1; then
  fail 'accepted unapproved signer with unchanged publisher contents'
fi
grep -qF 'signer revision is not approved by consumers' "$work/result" || {
  cat "$work/result" >&2
  fail 'unchanged unapproved signer failed for the wrong reason'
}
# A separately reviewed consumer-first approval admits the exact new identity.
sed "s|^approved_publisher_revision='.*'$|approved_publisher_revision='$release'|" \
  "$work/fetching.sh" >"$work/approved-release.sh"
git init --quiet "$work/consumer"
# shellcheck disable=SC2016 # jq variables, not shell expansion.
mutate '.jobs["publish-manifests"].uses = ($prefix + "@" + $release)'
run_guard "$work/approved-release.sh" "$work/consumer" >"$work/result" 2>&1 || {
  cat "$work/result" >&2
  fail 'rejected fetched explicitly approved release'
}
[[ ! -e "$work/consumer/.git/shallow" && ! -s "$work/consumer/.git/FETCH_HEAD" &&
  -z "$(git -C "$work/consumer" remote)" ]] || fail 'fetch changed consumer Git state'
while IFS=$'\t' read -r label mutation diagnostic; do
  mutate "$mutation"
  if run_guard "$work/offline.sh" "$work/source" >"$work/result" 2>&1; then
    fail "accepted $label"
  fi
  grep -qF -- "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    fail "$label failed for the wrong reason"
  }
done <<'CASES'
mutable ref	.jobs["publish-manifests"].uses=$prefix+"@main"	full immutable publisher reference
short ref	.jobs["publish-manifests"].uses=$prefix+"@"+$reviewed[0:12]	full immutable publisher reference
zero ref	.jobs["publish-manifests"].uses=$prefix+"@0000000000000000000000000000000000000000"	full immutable publisher reference
trailing newline	.jobs["publish-manifests"].uses=$prefix+"@"+$reviewed+"\n"	full immutable publisher reference
lookalike owner	.jobs["publish-manifests"].uses="outside/.github/.github/workflows/publish-manifests.yaml@"+$reviewed	full immutable publisher reference
lookalike path	.jobs["publish-manifests"].uses="devantler-tech/.github/.github/workflows/publish-manifestsXyaml@"+$reviewed	full immutable publisher reference
missing pin verification	del(.jobs["publish-manifests"].with["enable-caller-pin"])	verified-promotion inputs
disabled promotion	.jobs["publish-manifests"].with["enable-signed-promotion"]=false	verified-promotion inputs
wrong artifact	.jobs["publish-manifests"].with["oci-name"]="devantler-tech/other"	verified-promotion inputs
changed workflow	.jobs["publish-manifests"].uses=$prefix+"@"+$workflow	unreviewed publisher content
changed absence helper	.jobs["publish-manifests"].uses=$prefix+"@"+$absence	unreviewed publisher content
changed recovery helper	.jobs["publish-manifests"].uses=$prefix+"@"+$recovery	unreviewed publisher content
changed file mode	.jobs["publish-manifests"].uses=$prefix+"@"+$mode	unreviewed publisher content
unreadable revision	.jobs["publish-manifests"].uses=$prefix+"@0123456789abcdef0123456789abcdef01234567"	reference stays unverified
CASES
# shellcheck disable=SC2016 # jq variables, not shell expansion.
mutate '.jobs["publish-manifests"].uses=$prefix+"@"+$absence'
if run_guard "$work/fetching.sh" "$work/consumer" >"$work/result" 2>&1; then
  fail 'accepted fetched changed helper'
fi
grep -qF 'unreviewed publisher content' "$work/result" || fail 'fetched content refusal had the wrong cause'
echo 'ok caller requires explicit signer approval and reviewed contents, modes and safe inputs'
