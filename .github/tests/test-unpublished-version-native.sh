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
printf '127.0.0.1 registry.test\n' | sudo tee -a /etc/hosts >/dev/null
docker run --rm -d --name "$container" -p 127.0.0.1:5000:5000 --tmpfs /var/lib/registry \
  registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373 >/dev/null
"$work/proxy" "$work/cert.pem" "$work/key.pem" >"$work/requests" 2>&1 &
proxy_pid=$!
curl -fsS --retry 10 --retry-connrefused --retry-delay 1 --retry-max-time 30 --max-time 3 https://registry.test:5443/v2/ >/dev/null
export REGISTRY=registry.test:5443 ACTOR=fixture GH_TOKEN=synthetic-token VERSION=1.2.3
export OCI_REPOSITORIES=$'devantler-tech/app\ndevantler-tech/app/manifests'
guard="$root/.github/scripts/require-unpublished-version.sh"
bash "$guard"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}' >"$work/index.json"
digest="sha256:$(sha256sum "$work/index.json" | cut -d ' ' -f1)"
put() {
  local status
  status="$(curl -sS --max-time 10 -o "$work/response" -w '%{http_code}' \
    -H 'Content-Type: application/vnd.oci.image.index.v1+json' -X PUT --data-binary "@$work/index.json" \
    "https://$REGISTRY/v2/$1/manifests/$2")"
  [[ "$status" == 201 ]] || { echo "Native registry rejected fixture: HTTP $status" >&2; exit 1; }
}
read_digest() {
  curl -fsS --max-time 10 -H 'Accept: application/vnd.oci.image.index.v1+json' \
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
