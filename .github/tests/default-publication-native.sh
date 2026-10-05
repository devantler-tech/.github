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
if [[ "$PUBLICATION_FAULT" == alias-moved && "$kind" == manifests ]]; then
  "$REAL_FLUX" tag artifact "oci://$REGISTRY/devantler-tech/app/manifests@$OLD_MANIFEST_LATEST" \
    --tag "$VERSION" --creds "$ACTOR:$GH_TOKEN"
  printf 'moved manifests version\n' >>"$PUBLICATION_TRACE"
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
  faults=(none prerelease manifests-sign alias-moved)
  [[ "$family" != app ]] || faults+=(image-sign manifests-push)
  counter=0
  for fault in "${faults[@]}"; do
    counter=$((counter + 1))
    export VERSION="7.1.$counter" PUBLICATION_FAULT="$fault"
    [[ "$family" != app ]] || VERSION="7.2.$counter"
    [[ "$fault" != prerelease ]] || VERSION+=-rc.1
    export REF_NAME="v$VERSION"
    reset_latest >"$work/default-reset.log" 2>&1
    : >"$PUBLICATION_TRACE"
    rm -f "$work/default-produced.json"
    bash "$work/default-admission.sh" >"$work/default-admission.log" 2>&1
    status=0
    PATH="$work/publication-bin:$PATH" bash "$work/default-body.sh" >"$work/default-publication.log" 2>&1 || status=$?
    case "$fault" in
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
        ;;
      prerelease)
        [[ "$status" == 0 ]]
        [[ "$(readback devantler-tech/app latest)" == "$image_latest_before" &&
          "$(readback devantler-tech/app/manifests latest)" == "$latest_before" ]]
        ;;
      *)
        if [[ "$status" != 0 ]]; then cat "$work/default-publication.log" >&2; exit 1; fi
        produced="$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$work/default-produced.json")"
        # Verify the actual latest bytes with the real key, independently of the
        # adapter and the mutable version tag changed by the alias control.
        target_digest="$(readback devantler-tech/app/manifests latest)"
        [[ "$target_digest" == "$produced" && "$target_digest" != "$latest_before" ]]
        if [[ "$fault" == alias-moved ]]; then
          grep -qx 'moved manifests version' "$PUBLICATION_TRACE"
          [[ "$(readback devantler-tech/app/manifests "$VERSION")" == "$latest_before" ]]
        fi
        "$REAL_COSIGN" verify --allow-http-registry --allow-insecure-registry --insecure-ignore-tlog \
          --key "$FIXTURE_PUBLIC_KEY" "127.0.0.1:5000/devantler-tech/app/manifests@$target_digest" \
          >"$work/default-verify.json" 2>"$work/default-verify.log"
        if [[ "$family" == app ]]; then [[ "$(readback devantler-tech/app latest)" == "$image_digest" ]]; fi
        ;;
    esac
    echo "PASS: native default $family $fault registry readback"
  done
done
