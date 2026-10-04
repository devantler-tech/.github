#!/usr/bin/env bash
# Actual Registry V2 responses and immutable version bytes, with synthetic auth.
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'Native OCI version proof requires the Linux CI runner' >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
container="version-fixture-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
proxy_pid=''
cleanup() {
  code=$?
  if ((code != 0)); then
    for log in sign verify rejected; do
      [[ ! -s "$work/$log.log" ]] || { echo "Native claim $log diagnostics:" >&2; tail -n 12 "$work/$log.log" >&2; }
    done
  fi
  [[ -z "$proxy_pid" ]] || kill "$proxy_pid" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$code"
}
trap cleanup EXIT
go build -o "$work/proxy" "$root/.github/tests/fixtures/registry-auth-proxy.go"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 \
  -subj /CN=registry.test -addext 'subjectAltName=DNS:registry.test' >/dev/null 2>&1
export CURL_CA_BUNDLE="$work/cert.pem"
export SSL_CERT_FILE="$work/cert.pem"
printf '127.0.0.1 registry.test\n' | sudo tee -a /etc/hosts >/dev/null
docker run --rm -d --name "$container" -p 127.0.0.1:5000:5000 --tmpfs /var/lib/registry \
  registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
"$work/proxy" "$work/cert.pem" "$work/key.pem" >"$work/requests" 2>&1 &
proxy_pid=$!
curl -fsS --user fixture:synthetic-token --retry 10 --retry-connrefused --retry-delay 1 --retry-max-time 30 --max-time 3 https://registry.test:5443/v2/ >/dev/null
export REGISTRY=registry.test:5443 ACTOR=fixture GH_TOKEN=synthetic-token VERSION=1.2.3
export OCI_REPOSITORIES=$'devantler-tech/app\ndevantler-tech/app/manifests'
guard="$root/.github/scripts/require-unpublished-version.sh"
bash "$guard"
for authorization in '' 'Bearer wrong-token'; do
  status="$(curl -sS --max-time 10 -o "$work/response" -w '%{http_code}' \
    -H "Authorization: $authorization" "https://$REGISTRY/v2/devantler-tech/app/manifests/$VERSION")"
  [[ "$status" == 401 ]] || { echo 'FAIL: native fixture accepted an unauthenticated manifest read'; exit 1; }
done
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}' >"$work/index.json"
digest="sha256:$(sha256sum "$work/index.json" | cut -d ' ' -f1)"
put() {
  local status
  status="$(curl -sS --user fixture:synthetic-token --max-time 10 -o "$work/response" -w '%{http_code}' \
    -H 'Content-Type: application/vnd.oci.image.index.v1+json' -X PUT --data-binary "@$work/index.json" \
    "https://$REGISTRY/v2/$1/manifests/$2")"
  [[ "$status" == 201 ]] || { echo "Native registry rejected fixture: HTTP $status" >&2; exit 1; }
}
read_digest() {
  curl -fsS --max-time 10 -H 'Authorization: Bearer synthetic-bearer' -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://$REGISTRY/v2/$1/manifests/$2" >"$work/readback"
  printf 'sha256:%s\n' "$(sha256sum "$work/readback" | cut -d ' ' -f1)"
}
for target in devantler-tech/app devantler-tech/app/manifests; do
  put "$target" "$VERSION"
  put "$target" latest
  if bash "$guard" >"$work/refused.log" 2>&1; then echo 'FAIL: native existing version authorized a write'; exit 1; fi
  grep -q 'already exists' "$work/refused.log"
  [[ "$(read_digest "$target" "$VERSION")" == "$digest" && "$(read_digest "$target" latest)" == "$digest" ]]
done
# Build metadata normalization is performed by the real tag step.
for tag in v1.2.3+first v1.2.3+second; do
  GITHUB_OUTPUT="$work/output" REF_TYPE=tag REF_NAME="$tag" \
    bash -euo pipefail -c "$(yq -r '.jobs.publish.steps[] | select(.id == "version") | .run' "$root/.github/workflows/publish-app.yaml")"
  VERSION="$(sed -n 's/^version=//p' "$work/output" | tail -1)" bash "$guard" >"$work/refused.log" 2>&1 && { echo 'FAIL: normalized alias overwrote a version'; exit 1; }
  grep -q 'already exists' "$work/refused.log"
done
VERSION=1.2.4 bash "$guard"
VERSION=1.2.4-rc.1 bash "$guard"
echo 'PASS: native new/partial/paired versions and normalized aliases; version/latest bytes retained'

# Actual cryptographic verification of claims from the shipped production body.
# The ephemeral local key isolates this payload test from OIDC availability;
# production identity/issuer enforcement remains covered by the publisher steps.
export COSIGN_PASSWORD=''
cosign generate-key-pair --output-key-prefix "$work/claims" >/dev/null
image_digest="$digest"
put devantler-tech/app claims-staging
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[],"annotations":{"fixture":"manifests"}}' >"$work/index.json"
digest="sha256:$(sha256sum "$work/index.json" | cut -d ' ' -f1)"
manifest_digest="$digest"
put devantler-tech/app/manifests claims-staging
export REPOSITORY=devantler-tech/native-fixture SHA=fedcba9876543210fedcba9876543210fedcba98
export REF_NAME=v1.2.4+proof VERSION=1.2.4 RUN_ID=123 RUN_ATTEMPT=2
for family in app manifests; do
  export JOB_WORKFLOW_REF="devantler-tech/.github/.github/workflows/publish-$family.yaml@0123456789abcdef0123456789abcdef01234567"
  workflow="$root/.github/workflows/publish-$family.yaml"
  step='📦 Sign & promote manifests artifact'
  [[ "$family" != app ]] || step='📦 Sign & promote image and manifests'
  STEP="$step" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$workflow" >"$work/production.sh"
  awk '/^annotations=\(/ {copy=1} copy {print} copy && /^\)/ {exit}' "$work/production.sh" >"$work/annotations.sh"
  [[ -s "$work/annotations.sh" ]] || { echo 'FAIL: production has no signed publication claims'; exit 1; }
  export DIGEST="$image_digest" ARTIFACT_DIGEST="$manifest_digest"
  [[ "$family" != manifests ]] || DIGEST="$manifest_digest"
  annotations=()
  # shellcheck source=/dev/null # Extracted from our trusted production workflow.
  source "$work/annotations.sh"
  targets=("devantler-tech/app/manifests@$manifest_digest")
  [[ "$family" != app ]] || targets=("devantler-tech/app@$image_digest" "devantler-tech/app/manifests@$manifest_digest")
  for target in "${targets[@]}"; do
    reference="127.0.0.1:5000/$target"
    cosign sign --allow-http-registry --allow-insecure-registry --use-signing-config=false --tlog-upload=false --yes --key "$work/claims.key" "${annotations[@]}" "$reference" >"$work/sign.log" 2>&1
    cosign verify --allow-http-registry --allow-insecure-registry --insecure-ignore-tlog --key "$work/claims.pub" "${annotations[@]}" "$reference" >"$work/verified.json" 2>"$work/verify.log"
    jq -e --arg workflow "$JOB_WORKFLOW_REF" '
      length > 0 and all(.[];
        .optional["devantler.repository"] == "devantler-tech/native-fixture" and
        .optional["devantler.source-sha"] == "fedcba9876543210fedcba9876543210fedcba98" and
        .optional["devantler.source-ref"] == "v1.2.4+proof" and
        .optional["devantler.version"] == "1.2.4" and
        .optional["devantler.run-id"] == "123" and
        .optional["devantler.run-attempt"] == "2" and
        .optional["devantler.workflow-ref"] == $workflow)
    ' "$work/verified.json" >/dev/null
    [[ "$family" != app ]] || jq -e --arg image "$image_digest" --arg manifests "$manifest_digest" 'all(.[]; .optional["devantler.image-digest"] == $image and .optional["devantler.manifests-digest"] == $manifests)' "$work/verified.json" >/dev/null
    for ((index=1; index<${#annotations[@]}; index+=2)); do
      wrong=("${annotations[@]}")
      key="${wrong[index]%%=*}"
      wrong[index]="$key=wrong"
      if cosign verify --allow-http-registry --allow-insecure-registry --insecure-ignore-tlog --key "$work/claims.pub" "${wrong[@]}" "$reference" >"$work/rejected.json" 2>"$work/rejected.log"; then
        echo "FAIL: actual cosign accepted wrong signed $key" >&2
        exit 1
      fi
      grep -qi 'annotation' "$work/rejected.log" || { echo 'FAIL: claim rejection was an operational error'; exit 1; }
    done
  done
done
echo 'PASS: actual cosign validates all publication claims and rejects every wrong source/run/version/pair claim'

# Exercise the shipped recovery helper with actual Flux and registry bytes.
# Only Cosign's trust transport is adapted: original claims still undergo real
# cryptographic verification, independently signed above. Production OIDC is
# separately enforced by workflow/command contracts, not proven by a local key.
real_cosign="$(command -v cosign)"
mkdir "$work/bin"
cat >"$work/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == verify && "$2" == --certificate-identity && "$4" == --certificate-oidc-issuer &&
   "$5" == https://token.actions.githubusercontent.com ]] || exit 91
identity="$3"
[[ "$identity" =~ ^https://github.com/devantler-tech/\.github/\.github/workflows/publish-manifests\.yaml@[0-9a-f]{40}$ ]] || exit 92
shift 5
claims=()
keys=()
while [[ "${1:-}" == -a ]]; do
  [[ "$#" -ge 3 && "$2" == devantler.*=* ]] || exit 93
  key="${2%%=*}"
  for seen in "${keys[@]}"; do [[ "$seen" != "$key" ]] || exit 94; done
  keys+=("$key")
  claims+=(-a "$2")
  shift 2
done
[[ "${#keys[@]}" == 7 && "$#" == 1 &&
   "$1" == "registry.test:5443/devantler-tech/app/manifests@$RECOVERY_DIGEST" ]] || exit 95
exec "$REAL_COSIGN" verify --allow-http-registry --allow-insecure-registry --insecure-ignore-tlog \
  --key "$FIXTURE_PUBLIC_KEY" "${claims[@]}" "127.0.0.1:5000/${1#registry.test:5443/}"
COSIGN
chmod +x "$work/bin/cosign"
export REAL_COSIGN="$real_cosign" FIXTURE_PUBLIC_KEY="$work/claims.pub"
export ENABLE_SIGNED_PROMOTION=true ENABLE_CALLER_PIN=true OCI_NAME=devantler-tech/app SERVER_URL=https://github.com
export WORKFLOW_REPOSITORY=devantler-tech/.github
export JOB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/publish-manifests.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export RECOVERY_WORKFLOW_SHA=0123456789abcdef0123456789abcdef01234567
export RECOVERY_RUN_ID=123 RECOVERY_RUN_ATTEMPT=2 RECOVERY_DIGEST="$manifest_digest"
recovery="$root/.github/scripts/recover-manifests-version.sh"
latest_before="$(read_digest devantler-tech/app/manifests latest)"
[[ "$latest_before" != "$manifest_digest" ]]
recover() { PATH="$work/bin:$PATH" bash "$recovery" >"$work/recovery.log" 2>&1; }
writes() { grep -c '"PUT" "/v2/devantler-tech/app/manifests/manifests/1.2.4"' "$work/requests" || true; }
recover || { cat "$work/recovery.log" >&2; exit 1; }
[[ "$(read_digest devantler-tech/app/manifests 1.2.4)" == "$manifest_digest" &&
   "$(read_digest devantler-tech/app/manifests latest)" == "$latest_before" ]]
before="$(writes)"
recover
[[ "$(writes)" == "$before" ]] || { echo 'FAIL: matching recovery wrote again'; exit 1; }
# Valid but wrong claims must reach actual cryptographic annotation rejection.
for assignment in REPOSITORY=devantler-tech/wrong SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa REF_NAME=v1.2.4+wrong \
  VERSION=1.2.4-rc.1 RECOVERY_RUN_ID=124 RECOVERY_RUN_ATTEMPT=3 RECOVERY_WORKFLOW_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; do
  if (export "${assignment?}"; recover); then echo 'FAIL: wrong original claim recovered'; exit 1; fi
  grep -qi annotation "$work/recovery.log" || { cat "$work/recovery.log" >&2; echo 'FAIL: claim refused for unrelated reason'; exit 1; }
  [[ "$(writes)" == "$before" ]]
done
# Replacing the tag with contradictory bytes must never overwrite it.
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[],"annotations":{"fixture":"conflicting-version"}}' >"$work/index.json"
conflict_digest="sha256:$(sha256sum "$work/index.json" | cut -d ' ' -f1)"
put devantler-tech/app/manifests 1.2.4
before="$(writes)"
if recover; then echo 'FAIL: conflicting version was overwritten'; exit 1; fi
grep -q 'version has a conflicting digest' "$work/recovery.log"
[[ "$(writes)" == "$before" &&
   "$(read_digest devantler-tech/app/manifests 1.2.4)" == "$conflict_digest" &&
   "$(read_digest devantler-tech/app/manifests latest)" == "$latest_before" ]]
if grep -Eq 'synthetic-token|synthetic-bearer' "$work/recovery.log"; then echo 'FAIL: recovery printed credentials'; exit 1; fi
echo 'PASS: actual Flux restores original signed bytes; matching retry is a no-op; every wrong claim and conflicting version is refused; latest retained'
