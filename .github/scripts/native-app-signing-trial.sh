#!/usr/bin/env bash
# One-off native evidence: disposable TLS registry, actual producer scripts and GitHub OIDC.
set -euo pipefail
source_root="${1:?source checkout required}"
workflow="$source_root/.github/workflows/publish-app.yaml"
expected_source=09b7780f53fe513078ac146bd58787c52577baa1
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$expected_source" ]]
[[ "$TRIAL_HEAD" =~ ^[0-9a-f]{40}$ ]]
scratch="$(mktemp -d)"
container="app-native-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
cleanup() {
  local code=$?
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$scratch"
  exit "$code"
}
trap cleanup EXIT
for pair in 'caller:resolver' 'staging:staging' '📌 Pin image digest in manifests:pin' '📦 Sign & promote image and manifests:publish'; do
  STEP="${pair%:*}" yq -r '.jobs[].steps[] | select(.id == strenv(STEP) or .name == strenv(STEP)) | .run' "$workflow" >"$scratch/${pair##*:}.sh"
  [[ -s "$scratch/${pair##*:}.sh" && "$(cat "$scratch/${pair##*:}.sh")" != null ]]
done
GITHUB_OUTPUT="$scratch/caller.output" bash "$scratch/resolver.sh"
JOB_WORKFLOW_REF="$(sed -n 's/^ref=//p' "$scratch/caller.output")"
[[ "$JOB_WORKFLOW_REF" == "devantler-tech/.github/.github/workflows/native-app-signing-trial.yaml@$TRIAL_HEAD" ]]
export JOB_WORKFLOW_REF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -days 1 -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
cat /etc/ssl/certs/ca-certificates.crt "$scratch/cert.pem" >"$scratch/ca-bundle.pem"
export SSL_CERT_FILE="$scratch/ca-bundle.pem" CURL_CA_BUNDLE="$scratch/ca-bundle.pem"
sudo mkdir -p /etc/docker/certs.d/localhost:5443
sudo cp "$scratch/cert.pem" /etc/docker/certs.d/localhost:5443/ca.crt
docker run --rm -d --name "$container" -p 127.0.0.1:5443:5000 --tmpfs /var/lib/registry \
  -v "$scratch:/certs:ro" -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem -e REGISTRY_HTTP_TLS_KEY=/certs/key.pem \
  registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
curl -fsS --retry 10 --retry-connrefused --retry-delay 1 --retry-max-time 30 --max-time 3 https://localhost:5443/v2/ >/dev/null
mkdir "$scratch/deploy" "$scratch/build"
printf 'FROM scratch\nCOPY marker /marker\n' >"$scratch/build/Dockerfile"
export REGISTRY=localhost:5443 IMAGE_NAME=fixture REPOSITORY=devantler-tech/go-template
export SERVER_URL=https://github.com DEPLOY_PATH="$scratch/deploy" SHA="$expected_source"
export ACTOR=fixture GH_TOKEN=offline-fixture RUNNER_TEMP="$scratch" APP_NAME=fixture
export RUN_ID="$GITHUB_RUN_ID" RUN_ATTEMPT="$GITHUB_RUN_ATTEMPT"
manifest_digest() {
  local repository="$1" tag="$2" status
  status="$(curl -sS --max-time 10 -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' -o "$scratch/manifest" -w '%{http_code}' "https://$REGISTRY/v2/$repository/manifests/$tag")"
  [[ "$status" == 200 ]] || { echo "manifest read failed with HTTP $status" >&2; return 1; }
  printf 'sha256:%s\n' "$(sha256sum "$scratch/manifest" | cut -d ' ' -f1)"
}
absent() {
  local status
  status="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$REGISTRY/v2/$1/manifests/$2")"
  [[ "$status" == 404 ]]
}
build_staging() {
  printf '%s\n' "$VERSION" >"$scratch/build/marker"
  GITHUB_OUTPUT="$scratch/staging.output" bash "$scratch/staging.sh"
  tag="$(sed -n 's/^tag=//p' "$scratch/staging.output" | tail -1)"
  docker buildx build --builder default --push --provenance=false --tag "$tag" --metadata-file "$scratch/build.json" "$scratch/build"
  DIGEST="$(jq -r '.["containerimage.digest"]' "$scratch/build.json")"
  [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ && "$(manifest_digest fixture "staging-$RUN_ID-$RUN_ATTEMPT")" == "$DIGEST" ]]
  export DIGEST
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: fixture\nspec:\n  template:\n    spec:\n      containers:\n        - name: fixture\n          image: placeholder\n' >"$DEPLOY_PATH/deployment.yaml"
  IMAGE="$REGISTRY/$IMAGE_NAME" bash "$scratch/pin.sh"
  [[ "$(yq -r '.spec.template.spec.containers[0].image' "$DEPLOY_PATH/deployment.yaml")" == "$REGISTRY/$IMAGE_NAME@$DIGEST" ]]
}
export VERSION=1.2.3 REF_NAME=v1.2.3
build_staging
bash "$scratch/publish.sh"
stable_image="$DIGEST"
stable_manifests="$(manifest_digest fixture/manifests "$VERSION")"
[[ "$(manifest_digest fixture "$VERSION")" == "$stable_image" && "$(manifest_digest fixture latest)" == "$stable_image" ]]
[[ "$(manifest_digest fixture/manifests latest)" == "$stable_manifests" && "$(manifest_digest fixture/manifests "staging-$RUN_ID-$RUN_ATTEMPT")" == "$stable_manifests" ]]
cosign verify --certificate-identity "$SERVER_URL/$JOB_WORKFLOW_REF" --certificate-oidc-issuer https://token.actions.githubusercontent.com "$REGISTRY/fixture@$stable_image" >/dev/null
cosign verify --certificate-identity "$SERVER_URL/$JOB_WORKFLOW_REF" --certificate-oidc-issuer https://token.actions.githubusercontent.com "$REGISTRY/fixture/manifests@$stable_manifests" >/dev/null
echo 'PASS native stable app promotion: both signatures verify; image and manifests version/latest bytes equal produced staging digests'
export VERSION=1.2.4-rc.1 REF_NAME=v1.2.4-rc.1
build_staging
bash "$scratch/publish.sh"
[[ "$DIGEST" != "$stable_image" && "$(manifest_digest fixture "$VERSION")" == "$DIGEST" ]]
[[ "$(manifest_digest fixture/manifests "$VERSION")" == "$(manifest_digest fixture/manifests "staging-$RUN_ID-$RUN_ATTEMPT")" ]]
[[ "$(manifest_digest fixture latest)" == "$stable_image" && "$(manifest_digest fixture/manifests latest)" == "$stable_manifests" ]]
echo 'PASS native prerelease app promotion: distinct version digests; both latest pointers retained'
export VERSION=1.2.4 REF_NAME=v1.2.4
build_staging
export JOB_WORKFLOW_REF="${JOB_WORKFLOW_REF%@*}@0000000000000000000000000000000000000000"
if bash "$scratch/publish.sh" >"$scratch/wrong-identity.log" 2>&1; then echo 'FAIL accepted wrong signer identity' >&2; exit 1; fi
grep -Eq 'expected identities|certificate identity' "$scratch/wrong-identity.log"
absent fixture "$VERSION"; absent fixture/manifests "$VERSION"
[[ "$(manifest_digest fixture latest)" == "$stable_image" && "$(manifest_digest fixture/manifests latest)" == "$stable_manifests" ]]
echo 'PASS native wrong-identity app control: release tags absent; both latest pointers retained'
