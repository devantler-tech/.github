#!/usr/bin/env bash
# Pin, stage, sign, verify and only then expose one admitted release.
#
# Everything is signed by digest, as the calling workflow (keyless, GitHub OIDC). Both signatures
# must verify against that workflow's own identity at this tag before any selectable tag moves;
# a failure leaves only run-specific staging tags behind.
set +x
set -euo pipefail
umask 077
export LC_ALL=C

fail() {
  echo "::error::publish-app: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
issuer=https://token.actions.githubusercontent.com
identity="https://github.com/${GITHUB_WORKFLOW_REF:-}"
tag="${GITHUB_REF#refs/tags/}"
creds="${GITHUB_ACTOR:-}:${GH_TOKEN:-}"
run="${GITHUB_RUN_ID:-}-${GITHUB_RUN_ATTEMPT:-}"

[[ "${VERSION:-}" =~ ^[0-9A-Za-z][0-9A-Za-z.-]{0,127}$ ]] || fail 'admission did not resolve a version'
[[ "$run" =~ ^[0-9]+-[0-9]+$ ]] || fail 'require a numeric workflow run ID and attempt'
[[ "${ARTIFACT:-}" =~ ^ghcr\.io/[a-z0-9._/-]+/manifests$ ]] || fail 'admission did not resolve the manifests artifact'
[[ -n "${DEPLOY_PATH:-}" && -d "$DEPLOY_PATH" ]] || fail 'admission did not resolve the deploy path'
case "${MODE:-}" in
  deployment) digest="${BUILT_DIGEST:-}" ;;
  prebuilt-webapp) digest="${PREBUILT_DIGEST:-}" ;;
  manifests) digest='' ;;
  *) fail 'unknown mode' ;;
esac
if [[ "$MODE" != manifests ]]; then
  [[ "${IMAGE:-}" =~ ^ghcr\.io/[a-z0-9._/-]+$ ]] || fail 'admission did not resolve the image'
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'no valid image digest to publish'
fi

require_unpublished() { # <stage>
  echo "Checking that $VERSION is still unpublished ($1)."
  bash "$here/require-unpublished.sh"
}

# Deployment mode: inject the digest the build produced into the manifest admission resolved.
pin_image() {
  [[ -n "${MANIFEST:-}" && -f "$MANIFEST" && ! -L "$MANIFEST" ]] || fail 'admission did not resolve the app manifest'
  PIN="$IMAGE@$digest" yq -i \
    '(.spec.template.spec.containers[] | select(.name == strenv(APP_NAME)).image) = strenv(PIN)' "$MANIFEST"
  grep -qF "$IMAGE@$digest" "$MANIFEST" || fail "image pin did not apply to $MANIFEST"
}

# Push the WHOLE deploy path to an unselectable staging tag and report the digest it produced.
stage_manifests() {
  local pushed
  pushed="$(flux push artifact "oci://$ARTIFACT:staging-$run" \
    --path="$DEPLOY_PATH" \
    --source="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY" \
    --revision="$tag@sha1:$GITHUB_SHA" \
    --creds "$creds" \
    --output json)"
  manifests_digest="$(jq -r '.digest // ""' <<<"$pushed")"
  [[ "$manifests_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'flux push did not report the pushed artifact digest'
}

# Claims bind each signature to this publication; a verifier can require them.
annotate() {
  annotations=(
    -a "devantler.repository=$GITHUB_REPOSITORY"
    -a "devantler.source-sha=$GITHUB_SHA"
    -a "devantler.source-ref=$tag"
    -a "devantler.version=$VERSION"
    -a "devantler.run-id=$GITHUB_RUN_ID"
    -a "devantler.run-attempt=$GITHUB_RUN_ATTEMPT"
    -a "devantler.workflow-ref=$GITHUB_WORKFLOW_REF"
  )
  [[ "$MODE" == manifests ]] && return 0
  annotations+=(
    -a "devantler.image-digest=$digest"
    -a "devantler.manifests-digest=$manifests_digest"
  )
  if [[ "$MODE" == prebuilt-webapp ]]; then
    [[ "${PUBLIC_DIGEST:-}" =~ ^[0-9a-f]{64}$ && "${PREBUILT_CI_RUN_ID:-}" =~ ^[1-9][0-9]{0,14}$ &&
      "${PREBUILT_CI_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'missing verified original-image publication evidence'
    annotations+=(
      -a "devantler.public-digest=$PUBLIC_DIGEST"
      -a devantler.public-profile=production-template
      -a "devantler.ci-run-id=$PREBUILT_CI_RUN_ID"
      -a "devantler.ci-run-attempt=$PREBUILT_CI_RUN_ATTEMPT"
      -a "devantler.image-producer=https://github.com/$GITHUB_REPOSITORY/.github/workflows/ci.yaml@refs/heads/main"
    )
  fi
}

sign() {
  [[ "$MODE" == manifests ]] || cosign sign --yes "${annotations[@]}" "$IMAGE@$digest"
  cosign sign --yes "${annotations[@]}" "$ARTIFACT@$manifests_digest"
}

# Both digests must verify against the calling workflow at this tag before anything is exposed.
verify() {
  local ref
  for ref in ${IMAGE:+"$IMAGE@$digest"} "$ARTIFACT@$manifests_digest"; do
    cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
      "${annotations[@]}" "$ref" >/dev/null || fail "signature on $ref does not verify as $identity"
  done
}

# A registry-side copy must keep the signed digest before the release version points at it.
check_copy() {
  [[ "$MODE" != manifests ]] || return 0
  docker buildx imagetools create --prefer-index=false --tag "$IMAGE:verified-$run" \
    --metadata-file="$RUNNER_TEMP/publish-app-copy.json" "$IMAGE@$digest"
  [[ "$(jq -r '.["containerimage.descriptor"].digest // ""' "$RUNNER_TEMP/publish-app-copy.json")" == "$digest" ]] ||
    fail 'the image copy changed the verified digest'
}

expose() {
  local pointer
  for pointer in "$VERSION" latest; do
    # A prerelease is selectable by version but never becomes latest.
    [[ "$pointer" != latest || "$VERSION" != *-* ]] || continue
    [[ "$MODE" == manifests ]] || docker buildx imagetools create --prefer-index=false --tag "$IMAGE:$pointer" "$IMAGE@$digest"
    flux tag artifact "oci://$ARTIFACT@$manifests_digest" --tag "$pointer" --creds "$creds"
  done
}

require_unpublished before-staging
[[ "$MODE" != deployment ]] || pin_image
stage_manifests
annotate
sign
verify
check_copy
require_unpublished before-exposure
expose
{
  printf 'image-digest=%s\n' "$digest"
  printf 'manifests-digest=%s\n' "$manifests_digest"
} >>"$GITHUB_OUTPUT"
echo "Published $VERSION, signed and verified as $identity."
