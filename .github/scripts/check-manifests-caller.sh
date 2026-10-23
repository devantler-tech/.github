#!/usr/bin/env bash
# Require independently approved signer identity AND reviewed publisher contents.
set -euo pipefail
fail() {
  echo "FAIL: configuration caller: $*" >&2
  exit 1
}
[[ "$#" == 1 ]] || fail 'expected one caller workflow'
caller="$1"
encoded_ref="$(yq -o=json -I=0 '.jobs["publish-manifests"].uses // ""' "$caller")" ||
  fail 'cannot read publisher reference'
ref_pattern='^"devantler-tech/\.github/\.github/workflows/publish-manifests\.yaml@([0-9a-f]{40})"$'
[[ "$encoded_ref" =~ $ref_pattern ]] || fail 'expected a full immutable publisher reference'
revision="${BASH_REMATCH[1]}"
[[ "$revision" != 0000000000000000000000000000000000000000 ]] ||
  fail 'expected a full immutable publisher reference'
yq -e '
  (.jobs["publish-manifests"].with["enable-caller-pin"] == true) and
  (.jobs["publish-manifests"].with["enable-signed-promotion"] == true) and
  (.jobs["publish-manifests"].with["oci-name"] == "devantler-tech/github-config")
  ' "$caller" >/dev/null || fail 'expected verified-promotion inputs'

# The workflow pins every external action and copies exactly these two source helpers.
# Byte equivalence is not signer equivalence: the revision is part of the certificate
# identity. Update this revision only AFTER consumer approval has been deployed and
# read back. Content and file-mode review remain independently required.
approved_publisher_revision='0f390329b590404c02565b27a263ee841fa02bce'
reviewed_workflow_blob='ce9a9897b154486218478734a02c61e5ac3ea479'
reviewed_absence_blob='3566e4067e953a1d9cb34e6a50a0f9b72a5d8bc8'
reviewed_recovery_blob='48dc38f60ddebf90b0976758df9f1983bbb86bfd'
source_remote='https://github.com/devantler-tech/.github.git'
object_store=()
read_object() { git --no-replace-objects ${object_store[@]+"${object_store[@]}"} "$@"; }
if ! read_object cat-file -e "$revision" 2>/dev/null; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  git init --quiet --bare "$scratch/source.git"
  object_store=(--git-dir "$scratch/source.git")
  bounded=()
  if command -v timeout >/dev/null 2>&1; then bounded=(timeout 2m); fi
  ${bounded[@]+"${bounded[@]}"} git --no-replace-objects "${object_store[@]}" \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --quiet --no-tags --depth=1 --filter=blob:none "$source_remote" "$revision" 2>/dev/null ||
    fail 'publisher reference stays unverified: cannot read source commit'
fi
[[ "$(read_object cat-file -t "$revision" 2>/dev/null)" == commit ]] ||
  fail 'publisher reference stays unverified: not a commit'
while IFS=' ' read -r expected path; do
  actual="$(read_object ls-tree "$revision" -- "$path")" ||
    fail "publisher reference stays unverified: cannot read $path"
  [[ "$actual" == "100644 blob $expected"$'\t'"$path" ]] ||
    fail "unreviewed publisher content at $revision: $path; review its contents and mode before updating the approved blob"
done <<EOF
$reviewed_workflow_blob .github/workflows/publish-manifests.yaml
$reviewed_absence_blob .github/scripts/require-unpublished-version.sh
$reviewed_recovery_blob .github/scripts/recover-manifests-version.sh
EOF
[[ "$revision" == "$approved_publisher_revision" ]] ||
  fail 'signer revision is not approved by consumers; deploy and verify consumer approval before updating the recorded revision'
echo 'ok configuration caller pins an approved signer with reviewed contents and verified promotion'
