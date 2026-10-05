#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/publish-app.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "app-promotion: $*" >&2
  exit 1
}
# The build must select only staging in opt-in mode; checking the final shell
# step alone cannot catch a build that already exposed version/latest aliases.
# shellcheck disable=SC2016 # Literal workflow expression, not a Bash expansion.
expected_tags='${{ (inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == '\''true'\'') && steps.staging.outputs.tag || steps.meta.outputs.tags }}'
yq -o=json '.' "$workflow" | jq -e --arg tags "$expected_tags" '
  .on.workflow_call.inputs["enable-signed-promotion"].default == false and
  .jobs.publish.steps as $steps |
  ([$steps[] | select(.id == "build") | .with.tags] == [$tags]) and
  ([$steps | to_entries[] | select(.value.id == "staging") | .key][0] <
   [$steps | to_entries[] | select(.value.id == "build") | .key][0])
' >/dev/null || fail 'image build does not enforce default-off staging before publication'
mkdir -p "$work/bin" "$work/state"
cp "$root/.github/scripts/require-unpublished-version.sh" "$work/require-unpublished-version.sh"
cp "$root/.github/tests/fixtures/registry-read-curl.sh" "$work/bin/curl"
yq -r '.jobs.publish.steps[] | select(.id == "staging") | .run' "$workflow" >"$work/staging.sh"
yq -r '.jobs.publish.steps[] | select(.name == "📦 Sign & promote image and manifests") | .run' "$workflow" >"$work/promote.sh"
yq -r '.jobs.publish.steps[] | select(.name == "📦 Push & sign manifests artifact") | .run' "$workflow" >"$work/default.sh"
[[ -s "$work/staging.sh" && -s "$work/promote.sh" ]] || fail 'missing production promotion steps'
image_digest="sha256:$(printf 'b%.0s' {1..64})"
manifest_digest="sha256:$(printf 'a%.0s' {1..64})"
cat >"$work/bin/flux" <<'FLUX'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s\n' "$*" >>"$TRACE"
if [[ "$1 $2" == 'push artifact' ]]; then
  [[ "$FAULT" != manifest-push ]] || exit 23
  printf '{"digest":"%s"}\n' "$MANIFEST_DIGEST"
else
  if [[ "$SIGNED_PROMOTION" == true ]]; then
    [[ -e "$STATE/image-verified" && -e "$STATE/manifest-verified" ]] || exit 24
  fi
fi
FLUX
cp "$root/.github/tests/fixtures/publication-claims-cosign.sh" "$work/bin/cosign"
cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$TRACE"
if [[ "$SIGNED_PROMOTION" == true ]]; then
  [[ -e "$STATE/image-verified" && -e "$STATE/manifest-verified" ]] || exit 24
else
  [[ -e "$STATE/image-signed" && -e "$STATE/manifest-signed" ]] || exit 24
fi
[[ "$*" == *'--prefer-index=false'* && "$*" == *"@$IMAGE_DIGEST"* ]] || exit 25
[[ "$FAULT" != image-promotion ]] || exit 23
for arg in "$@"; do
  if [[ "$arg" == --metadata-file=* ]]; then
    digest="$IMAGE_DIGEST"
    [[ "$FAULT" != changed-digest ]] || digest=sha256:changed
    printf '{"containerimage.descriptor":{"digest":"%s"}}\n' "$digest" >"${arg#*=}"
  fi
done
DOCKER
chmod +x "$work/bin/"*
run_step() {
  env PATH="$work/bin:$PATH" TRACE="$work/trace" STATE="$work/state" FAULT="$1" \
    IMAGE_DIGEST="$image_digest" MANIFEST_DIGEST="$manifest_digest" DIGEST="${5:-$image_digest}" \
    SIGNED_PROMOTION="${6:-true}" IMAGE=ghcr.io/devantler-tech/app \
    REGISTRY=ghcr.io IMAGE_NAME=devantler-tech/app DEPLOY_PATH=./deploy \
    VERSION="$2" REF_NAME="v$2" SHA=fedcba9876543210fedcba9876543210fedcba98 \
    SERVER_URL=https://github.com REPOSITORY=devantler-tech/app ACTOR=fixture GH_TOKEN=fixture \
    JOB_WORKFLOW_REF="$3" RUN_ID=123 RUN_ATTEMPT=2 GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 RUNNER_TEMP="$work" \
    GITHUB_OUTPUT="$work/output" bash --noprofile --norc -eo pipefail "$4"
}
identity=devantler-tech/.github/.github/workflows/publish-app.yaml@0123456789abcdef0123456789abcdef01234567
for bad in '' 'devantler-tech/.github/.github/workflows/publish-app.yaml@main'; do
  : >"$work/trace"
  if run_step none 1.2.3 "$bad" "$work/staging.sh" >"$work/log" 2>&1; then fail 'accepted mutable or absent signer before image push'; fi
  [[ ! -s "$work/trace" ]] || fail 'invalid staging identity reached registry'
done
: >"$work/output"
run_step none 1.2.3 "$identity" "$work/staging.sh"
grep -qx 'tag=ghcr.io/devantler-tech/app:staging-123-2' "$work/output" || fail 'wrong staging reference'
: >"$work/trace"
for fault in registry-existing registry-image-only registry-manifests-only; do
  if run_step "$fault" 1.2.3 "$identity" "$work/staging.sh" >"$work/log" 2>&1; then fail "$fault authorized image staging"; fi
  [[ ! -s "$work/trace" ]] || fail 'existing version made a registry write'
done
for fault in manifest-push image-sign manifest-sign image-verify manifest-verify image-promotion changed-digest registry-existing; do
  rm -f "$work/state/"* "$work/trace"
  if run_step "$fault" 1.2.3 "$identity" "$work/promote.sh" >"$work/log" 2>&1; then fail "accepted failed $fault"; fi
  if grep -q 'latest' "$work/trace"; then fail "advanced latest after failed $fault"; fi
  if grep -qE '(--tag 1.2.3|--tag ghcr.io/devantler-tech/app:1.2.3)' "$work/trace"; then fail "exposed version after failed staging or verification: $fault"; fi
done
for kind in image manifest; do
  for key in repository source-sha source-ref version run-id run-attempt workflow-ref image-digest manifests-digest; do
    rm -f "$work/state/"* "$work/trace"
    if run_step "claim-$kind-devantler.$key" 1.2.3 "$identity" "$work/promote.sh" >"$work/log" 2>&1; then fail "accepted conflicting $kind $key"; fi
    grep -q 'claims: signed payload mismatch' "$work/log" || fail 'claim rejection failed for an unrelated reason'
    if grep -qE '(latest|--tag 1.2.3|--tag ghcr.io/devantler-tech/app:1.2.3)' "$work/trace"; then fail 'conflicting claim exposed a release tag'; fi
  done
done
echo 'app-promotion: every source/run claim and both paired digests block promotion on either signature'
for version in 1.2.3 1.2.3-rc.1; do
  rm -f "$work/state/"* "$work/trace"
  run_step none "$version" "$identity" "$work/promote.sh" >"$work/log" 2>&1 || fail "healthy $version failed: $(cat "$work/log")"
  grep -qF "oci://ghcr.io/devantler-tech/app/manifests@$manifest_digest --tag $version" "$work/trace" || fail 'manifest version did not use verified digest'
  if [[ "$version" == *-* ]]; then
    ! grep -q latest "$work/trace" || fail 'prerelease advanced latest'
  else
    [[ "$(grep -c latest "$work/trace")" == 2 ]] || fail 'stable release did not promote both latest tags'
  fi
done
echo 'app-promotion: healthy stable/prerelease and signing, verification, push and digest failures pass'

for fault in manifest-push image-sign manifest-sign changed-digest image-promotion; do
  rm -f "$work/state/"* "$work/trace"
  if run_step "$fault" 1.2.3 '' "$work/default.sh" "$image_digest" false >"$work/log" 2>&1; then
    fail "default accepted failed $fault"
  fi
  ! grep -q latest "$work/trace" || fail "default advanced latest after failed $fault"
done
for version in 1.2.3 1.2.3-rc.1; do
  rm -f "$work/state/"* "$work/trace"
  run_step none "$version" '' "$work/default.sh" "$image_digest" false >"$work/log" 2>&1 ||
    fail "default healthy $version failed: $(cat "$work/log")"
  [[ -e "$work/state/image-signed" && -e "$work/state/manifest-signed" ]] || fail 'default omitted a paired signature'
  if [[ "$version" == *-* ]]; then
    ! grep -q latest "$work/trace" || fail 'default prerelease advanced latest'
  else
    [[ "$(grep -c latest "$work/trace")" == 2 ]] || fail 'default stable release did not promote both latest tags'
    grep -qF "oci://ghcr.io/devantler-tech/app/manifests@$manifest_digest --tag latest" "$work/trace" ||
      fail 'default manifests latest used a mutable version alias'
  fi
done
yq -o=json '.jobs.publish.steps[] | select(.id == "meta") | .with' "$workflow" |
  jq -e '.flavor == "latest=false" and (.tags | contains("value=latest") | not)' >/dev/null ||
  fail 'default builder metadata can expose latest before signing'
echo 'app-promotion: default stable/prerelease and paired push/sign failures preserve latest safety'

if [[ "$#" == 0 ]]; then
  for mutation in early-image-tags missing-verification missing-version-refusal missing-manifests-refusal default-metadata default-manifest-alias default-signature default-prerelease; do
    # shellcheck disable=SC2016 # Literal workflow expression in the negative control.
    case "$mutation" in
      early-image-tags) expression='(.jobs.publish.steps[] | select(.id == "build")).with.tags = "${{ steps.meta.outputs.tags }}"' ;;
      missing-verification) expression='(.jobs.publish.steps[] | select(.name == "📦 Sign & promote image and manifests")).run |= sub("cosign verify"; "echo verify")' ;;
      missing-version-refusal) expression='(.jobs.publish.steps[] | select(.id == "staging")).run |= sub("bash.*require-unpublished-version[.]sh.*"; "true")' ;;
      missing-manifests-refusal) expression='(.jobs.publish.steps[] | select(.id == "staging")).run |= sub("\\$name/manifests"; "$name")' ;;
      default-metadata) expression='(.jobs.publish.steps[] | select(.id == "meta")).with.flavor = "latest=auto"' ;;
      default-manifest-alias) expression='(.jobs.publish.steps[] | select(.name == "📦 Push & sign manifests artifact")).run |= sub("oci://\\$\\{ARTIFACT\\}@\\$\\{ARTIFACT_DIGEST\\}"; "oci://${ARTIFACT}:${VERSION}")' ;;
      default-signature) expression='(.jobs.publish.steps[] | select(.name == "📦 Push & sign manifests artifact")).run |= sub("cosign sign --yes \\\"\\$\\{IMAGE\\}@\\$\\{DIGEST\\}\\\""; "true")' ;;
      default-prerelease) expression='(.jobs.publish.steps[] | select(.name == "📦 Push & sign manifests artifact")).run |= sub("\\*-\\*\\) ;;"; "*-*) docker buildx imagetools create --prefer-index=false --tag \"${IMAGE}:latest\" \"${IMAGE}@${DIGEST}\" ;;")' ;;
    esac
    yq "$expression" "$workflow" >"$work/mutated.yaml"
    [[ "$(cat "$work/mutated.yaml")" != "$(cat "$workflow")" ]] || fail "mutation did not change workflow: $mutation"
    if bash "$0" "$work/mutated.yaml" >"$work/mutation.log" 2>&1; then fail "accepted unsafe mutation: $mutation"; fi
  done
  echo 'app-promotion: early image publication and missing verification mutations fail'
fi
