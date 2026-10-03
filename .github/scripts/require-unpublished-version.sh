#!/usr/bin/env bash
# Only an authenticated, definitive absence permits a release write.
set -euo pipefail
umask 077
fail() { echo "::error::cannot establish an unpublished release version: $*" >&2; exit 1; }
[[ "${REGISTRY:-}" =~ ^[a-z0-9.-]+(:[0-9]+)?$ ]] || fail 'invalid registry host'
[[ "${VERSION:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'invalid normalized OCI version'
[[ -n "${ACTOR:-}" && -n "${GH_TOKEN:-}" ]] || fail 'missing registry credentials'
[[ -n "${OCI_REPOSITORIES:-}" ]] || fail 'no publication targets'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'
while IFS= read -r repository; do
  [[ "$repository" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] || fail 'invalid OCI repository'
  [[ "${#repository}" -lt 256 ]] || fail 'OCI repository is too long'
  # The service and scope are encoded as query parameters, never interpolated
  # into an authentication URL supplied by the registry response. No redirects
  # are followed, and credentials can leave only for the declared registry.
  status="$(curl -q --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output "$work/token.json" --write-out '%{http_code}' --get \
    --data-urlencode "service=$REGISTRY" --data-urlencode "scope=repository:$repository:pull" \
    --user "$ACTOR:$GH_TOKEN" "https://$REGISTRY/token")" || fail 'registry authentication request failed'
  [[ "$status" == 200 ]] || fail "registry authentication returned HTTP $status"
  token="$(jq -ser 'select(length == 1) | .[0] | select(type == "object") |
    select(.token == null or .access_token == null or .token == .access_token) |
    (.token // .access_token) | select(type == "string" and length > 0)' "$work/token.json" 2>/dev/null)" || fail 'invalid registry token response'
  [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || fail 'invalid registry bearer token'
  status="$(curl -q --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output "$work/manifest.json" --write-out '%{http_code}' \
    --header "Authorization: Bearer $token" --header "Accept: $accept" \
    "https://$REGISTRY/v2/$repository/manifests/$VERSION")" || fail 'registry version read failed'
  unset token
  case "$status" in
    200) fail "version $VERSION already exists in $repository; publish a new version" ;;
    404)
      jq -se 'length == 1 and (.[0] | type == "object" and (.errors | type == "array" and length > 0 and
        all(.[]; type == "object" and (.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN"))))' \
        "$work/manifest.json" >/dev/null 2>&1 || fail 'registry did not establish version absence'
      ;;
    *) fail "registry version read returned HTTP $status" ;;
  esac
done <<<"$OCI_REPOSITORIES"
echo "Release version $VERSION is absent from every publication target."
