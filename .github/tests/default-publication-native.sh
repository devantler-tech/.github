#!/usr/bin/env bash
# Execute default production steps against the parent's disposable registry.
# Local-key signatures prove bytes and ordering; they do not prove production OIDC.
set -euo pipefail
work="${1:?disposable registry workspace required}"
image_digest="${image_digest:?parent image digest required}"
image_latest_before="${image_latest_before:?parent image latest digest required}"
latest_before="${latest_before:?parent manifests latest digest required}"
for digest in "$image_digest" "$image_latest_before" "$latest_before"; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 91
done
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$work/publication-bin" "$work/default-deploy"
cat >"$work/default-deploy/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: publication-fixture
data:
  value: signed-release
YAML
REAL_FLUX="$(command -v flux)"
REAL_DOCKER="$(command -v docker)"
export REAL_FLUX REAL_DOCKER
export FIXTURE_PRIVATE_KEY="$work/claims.key" FIXTURE_PUBLIC_KEY="$work/claims.pub"
export PUBLICATION_TRACE="$work/publication-trace" PUBLICATION_WORK="$work"
cat >"$work/publication-bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 3 && "$1" == sign && "$2" == --yes &&
  "$3" =~ ^registry\.test:5443/devantler-tech/app(/manifests)?@sha256:[0-9a-f]{64}$ ]] || exit 91
kind=image
[[ "$3" != */manifests@* ]] || kind=manifests
printf 'sign %s\n' "$kind" >>"$PUBLICATION_TRACE"
[[ "$PUBLICATION_FAULT" != "$kind-sign" ]] || exit 23
"$REAL_COSIGN" sign --allow-http-registry --allow-insecure-registry --use-signing-config=false \
  --tlog-upload=false --yes --key "$FIXTURE_PRIVATE_KEY" "127.0.0.1:5000/${3#registry.test:5443/}" \
  >"$PUBLICATION_WORK/default-sign.log" 2>&1
if [[ ( "$PUBLICATION_FAULT" == alias-moved || "$PUBLICATION_FAULT" == raced-version ) && "$kind" == manifests ]]; then
  tag="default-staging-${RUN_ID}-${RUN_ATTEMPT}"
  [[ "$PUBLICATION_FAULT" != raced-version ]] || tag="$VERSION"
  "$REAL_FLUX" tag artifact "oci://$REGISTRY/devantler-tech/app/manifests@$OLD_MANIFEST_LATEST" \
    --tag "$tag" --creds "$ACTOR:$GH_TOKEN"
  printf 'moved manifests %s\n' "$tag" >>"$PUBLICATION_TRACE"
fi
COSIGN
cat >"$work/publication-bin/flux" <<'FLUX'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s %s\n' "$1" "$2" >>"$PUBLICATION_TRACE"
if [[ "$1 $2" == 'push artifact' ]]; then
  [[ "$PUBLICATION_FAULT" != manifests-push ]] || exit 23
  "$REAL_FLUX" "$@" | tee "$PUBLICATION_WORK/default-produced.json"
  exit
fi
exec "$REAL_FLUX" "$@"
FLUX
cat >"$work/publication-bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker promotion\n' >>"$PUBLICATION_TRACE"
if [[ "$PUBLICATION_FAULT" == changed-digest ]]; then
  # Use the real CLI to wrap the single-platform fixture in a new index.
  # The metadata and registry bytes must both show the changed descriptor.
  args=()
  for arg in "$@"; do
    [[ "$arg" != --prefer-index=false ]] || arg=--prefer-index=true
    args+=("$arg")
  done
  exec "$REAL_DOCKER" "${args[@]}"
fi
exec "$REAL_DOCKER" "$@"
DOCKER
chmod +x "$work/publication-bin/"*
cp "$root/.github/scripts/require-unpublished-version.sh" "$work/require-unpublished-version.sh"
export RUNNER_TEMP="$work" DEPLOY_PATH="$work/default-deploy"
export IMAGE_NAME=devantler-tech/app IMAGE="$REGISTRY/devantler-tech/app" OCI_NAME=devantler-tech/app
export REPOSITORY=devantler-tech/native-fixture SERVER_URL=https://github.com
export SHA=fedcba9876543210fedcba9876543210fedcba98 DIGEST="$image_digest"
export OLD_MANIFEST_LATEST="$latest_before"
readback() {
  curl -fsS --max-time 10 -H 'Authorization: Bearer synthetic-bearer' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' \
    "https://$REGISTRY/v2/$1/manifests/$2" >"$work/default-readback"
  printf 'sha256:%s\n' "$(sha256sum "$work/default-readback" | cut -d ' ' -f1)"
}
reset_latest() {
  "$REAL_FLUX" tag artifact "oci://$REGISTRY/devantler-tech/app@$image_latest_before" --tag latest --creds "$ACTOR:$GH_TOKEN"
  "$REAL_FLUX" tag artifact "oci://$REGISTRY/devantler-tech/app/manifests@$latest_before" --tag latest --creds "$ACTOR:$GH_TOKEN"
}
for family in manifests app; do
  workflow="$root/.github/workflows/publish-$family.yaml"
  STEP='📦 Push & sign manifests artifact' yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' \
    "$workflow" >"$work/default-body.sh"
  STEP='🔒 Refuse an occupied release version' yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' \
    "$workflow" >"$work/default-admission.sh"
  [[ -s "$work/default-body.sh" && -s "$work/default-admission.sh" ]]
  faults=(none prerelease manifests-sign alias-moved raced-version)
  [[ "$family" != app ]] || faults+=(image-sign manifests-push changed-digest)
  counter=0
  for fault in "${faults[@]}"; do
    counter=$((counter + 1))
    export VERSION="7.1.$counter" PUBLICATION_FAULT="$fault"
    [[ "$family" != app ]] || VERSION="7.2.$counter"
    [[ "$fault" != prerelease ]] || VERSION+=-rc.1
    export REF_NAME="v$VERSION"
    export GITHUB_RUN_ID="$((9000 + counter))" GITHUB_RUN_ATTEMPT=1
    export RUN_ID="$GITHUB_RUN_ID" RUN_ATTEMPT="$GITHUB_RUN_ATTEMPT" ENABLE_SIGNED_PROMOTION=false
    export IMAGE_TAGS
    IMAGE_TAGS="$(printf '%s:%s\n%s:sha-fedcba9' "$IMAGE" "$VERSION" "$IMAGE")"
    reset_latest >"$work/default-reset.log" 2>&1
    : >"$PUBLICATION_TRACE"
    rm -f "$work/default-produced.json"
    status=0
    bash "$work/default-admission.sh" >"$work/default-admission.log" 2>&1 || status=$?
    if [[ "$status" != 0 ]]; then cat "$work/default-admission.log" >&2; exit "$status"; fi
    if [[ "$family" == app ]]; then
      : >"$work/default-staging-output"
      GITHUB_OUTPUT="$work/default-staging-output" JOB_WORKFLOW_REF='' \
        bash -euo pipefail -c "$(yq -r '.jobs.publish.steps[] | select(.id == "staging") | .run' "$workflow")" \
        >"$work/default-staging.log" 2>&1
      tag="$(sed -n 's/^tag=//p' "$work/default-staging-output" | tail -1)"
      [[ "$tag" == "$IMAGE:staging-${RUN_ID}-${RUN_ATTEMPT}" ]]
      "$REAL_DOCKER" buildx imagetools create --prefer-index=false --tag "$tag" "$IMAGE@$DIGEST" \
        >"$work/default-build.log" 2>&1
      [[ "$(readback devantler-tech/app "${tag##*:}")" == "$DIGEST" ]]
    fi
    status=0
    PATH="$work/publication-bin:$PATH" bash "$work/default-body.sh" >"$work/default-publication.log" 2>&1 || status=$?
    case "$fault" in
      raced-version)
        [[ "$status" == 1 ]]
        grep -qF "version $VERSION already exists" "$work/default-publication.log"
        [[ "$(readback devantler-tech/app/manifests "$VERSION")" == "$latest_before" ]]
        [[ "$(readback devantler-tech/app latest)" == "$image_latest_before" &&
          "$(readback devantler-tech/app/manifests latest)" == "$latest_before" ]]
        ! grep -qx 'flux tag artifact' "$PUBLICATION_TRACE"
        ;;
      changed-digest)
        [[ "$status" == 1 ]]
        grep -qF 'staged image digest differs from the signed image' "$work/default-publication.log"
        copied="$(jq -er '."containerimage.descriptor".digest | select(test("^sha256:[0-9a-f]{64}$"))' "$work/default-image-staging.json")"
        [[ "$copied" != "$image_digest" ]]
        [[ "$(readback devantler-tech/app "default-staging-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}")" == "$copied" ]]
        [[ "$(readback devantler-tech/app latest)" == "$image_latest_before" &&
          "$(readback devantler-tech/app/manifests latest)" == "$latest_before" ]]
        bash "$work/default-admission.sh" >"$work/default-absence.log" 2>&1 || {
          cat "$work/default-absence.log" >&2; echo 'FAIL: changed descriptor exposed a version' >&2; exit 1;
        }
        ! grep -qx 'flux tag artifact' "$PUBLICATION_TRACE"
        ;;
      manifests-sign|image-sign|manifests-push)
        [[ "$status" == 23 ]]
        if [[ "$fault" == manifests-push ]]; then
          grep -qx 'flux push artifact' "$PUBLICATION_TRACE"
        else
          grep -qx "sign ${fault%-sign}" "$PUBLICATION_TRACE"
        fi
        ! grep -qE 'docker promotion|flux tag artifact' "$PUBLICATION_TRACE"
        [[ "$(readback devantler-tech/app latest)" == "$image_latest_before" &&
          "$(readback devantler-tech/app/manifests latest)" == "$latest_before" ]]
        bash "$work/default-admission.sh" >"$work/default-absence.log" 2>&1 || {
          cat "$work/default-absence.log" >&2; echo 'FAIL: failed publication exposed a version' >&2; exit 1;
        }
        ;;
      prerelease)
        [[ "$status" == 0 ]]
        produced="$(jq -er '.digest' "$work/default-produced.json")"
        [[ "$(readback devantler-tech/app/manifests "$VERSION")" == "$produced" ]]
        if [[ "$family" == app ]]; then
          [[ "$(readback devantler-tech/app "$VERSION")" == "$image_digest" &&
            "$(readback devantler-tech/app sha-fedcba9)" == "$image_digest" ]]
        fi
        [[ "$(readback devantler-tech/app latest)" == "$image_latest_before" &&
          "$(readback devantler-tech/app/manifests latest)" == "$latest_before" ]]
        ;;
      *)
        if [[ "$status" != 0 ]]; then cat "$work/default-publication.log" >&2; exit 1; fi
        produced="$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$work/default-produced.json")"
        # Verify the actual latest bytes with the real key, independently of the
        # adapter and the mutable staging tag changed by the alias control.
        target_digest="$(readback devantler-tech/app/manifests latest)"
        [[ "$target_digest" == "$produced" && "$target_digest" != "$latest_before" ]]
        [[ "$(readback devantler-tech/app/manifests "$VERSION")" == "$produced" ]]
        if [[ "$fault" == alias-moved ]]; then
          grep -qx "moved manifests default-staging-${RUN_ID}-${RUN_ATTEMPT}" "$PUBLICATION_TRACE"
          [[ "$(readback devantler-tech/app/manifests "default-staging-${RUN_ID}-${RUN_ATTEMPT}")" == "$latest_before" ]]
        fi
        "$REAL_COSIGN" verify --allow-http-registry --allow-insecure-registry --insecure-ignore-tlog \
          --key "$FIXTURE_PUBLIC_KEY" "127.0.0.1:5000/devantler-tech/app/manifests@$target_digest" \
          >"$work/default-verify.json" 2>"$work/default-verify.log"
        if [[ "$family" == app ]]; then
          [[ "$(readback devantler-tech/app latest)" == "$image_digest" &&
            "$(readback devantler-tech/app "$VERSION")" == "$image_digest" &&
            "$(readback devantler-tech/app sha-fedcba9)" == "$image_digest" ]]
        fi
        ;;
    esac
    echo "PASS: native default $family $fault registry readback"
  done
done
