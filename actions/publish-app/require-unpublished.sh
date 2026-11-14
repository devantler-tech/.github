#!/usr/bin/env bash
# Refuse a release version that already exists in any repository this release writes to. Only an
# authenticated, definitive absence passes.
#
# The same contract as .github/scripts/require-unpublished-version.sh, which the retiring reusable
# workflows keep unchanged, except that no credential ever reaches a command line: curl reads the
# registry login and the bearer token from private config files that are removed on exit.
set +x
set -euo pipefail
umask 077
export LC_ALL=C

fail() {
  echo "::error::publish-app cannot establish an unpublished release version: $*" >&2
  exit 1
}

registry=ghcr.io
[[ "${VERSION:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'invalid normalized OCI version'
[[ "${GITHUB_ACTOR:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$ ]] || fail 'invalid registry user'
# Opaque transport data: exclude whitespace, controls and curl-config quoting without parsing it.
[[ -n "${GH_TOKEN:-}" && "$GH_TOKEN" != *[!A-Za-z0-9._~+/=-]* ]] || fail 'missing or unsafe registry token'
[[ "${ARTIFACT:-}" == "$registry/"* ]] || fail 'missing manifests artifact name'
repositories=("${ARTIFACT#"$registry/"}")
if [[ -n "${IMAGE:-}" ]]; then
  [[ "$IMAGE" == "$registry/"* ]] || fail 'invalid image name'
  repositories=("${IMAGE#"$registry/"}" "${repositories[@]}")
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'user = "%s:%s"\n' "$GITHUB_ACTOR" "$GH_TOKEN" >"$work/login.curlrc"
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'
for repository in "${repositories[@]}"; do
  [[ "$repository" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] || fail 'invalid OCI repository'
  [[ "${#repository}" -lt 256 ]] || fail 'OCI repository is too long'
  # The service and scope are query parameters, never an authentication URL from the registry's
  # response. No redirects are followed, so the login leaves only for the declared registry.
  status="$(curl -q --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output "$work/token.json" --write-out '%{http_code}' --get \
    --data-urlencode "service=$registry" --data-urlencode "scope=repository:$repository:pull" \
    --config "$work/login.curlrc" "https://$registry/token")" || fail 'registry authentication request failed'
  [[ "$status" == 200 ]] || fail "registry authentication returned HTTP $status"
  token="$(jq -ser 'select(length == 1) | .[0] | select(type == "object") |
    select(.token == null or .access_token == null or .token == .access_token) |
    (.token // .access_token) | select(type == "string" and length > 0)' "$work/token.json" 2>/dev/null)" ||
    fail 'invalid registry token response'
  [[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || fail 'invalid registry bearer token'
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$work/bearer.curlrc"
  unset token
  status="$(curl -q --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 30 --max-filesize 1048576 \
    --output "$work/manifest.json" --write-out '%{http_code}' \
    --config "$work/bearer.curlrc" --header "Accept: $accept" \
    "https://$registry/v2/$repository/manifests/$VERSION")" || fail 'registry version read failed'
  rm -f "$work/bearer.curlrc"
  case "$status" in
    200) fail "version $VERSION already exists in $repository; publish a new version" ;;
    404)
      jq -se 'length == 1 and (.[0] | type == "object" and (.errors | type == "array" and length > 0 and
        all(.[]; type == "object" and (.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN"))))' \
        "$work/manifest.json" >/dev/null 2>&1 || fail 'registry did not establish version absence'
      ;;
    *) fail "registry version read returned HTTP $status" ;;
  esac
done
echo "Release version $VERSION is absent from every publication target."
