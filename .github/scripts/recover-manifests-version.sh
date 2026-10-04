#!/usr/bin/env bash
# Restore only a missing version alias from an authenticated original digest.
set -euo pipefail
umask 077
fail() { echo "::error::manifests recovery refused: $*" >&2; exit 1; }
[[ "${ENABLE_SIGNED_PROMOTION:-}" == true && "${ENABLE_CALLER_PIN:-}" == true ]] || fail 'signed promotion and caller pinning are required'
[[ "${REGISTRY:-}" =~ ^[a-z0-9.-]+(:[0-9]+)?$ ]] || fail 'invalid registry host'
[[ "${VERSION:-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'invalid normalized version'
[[ "${RECOVERY_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'invalid original digest'
[[ "${RECOVERY_WORKFLOW_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'original producer must be immutable'
[[ "${RECOVERY_RUN_ID:-}" =~ ^[0-9]+$ && "${RECOVERY_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]] || fail 'invalid original run identity'
[[ "${SHA:-}" =~ ^[0-9a-f]{40}$ && -n "${REF_NAME:-}" && -n "${REPOSITORY:-}" ]] || fail 'missing source identity'
[[ "${WORKFLOW_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'invalid workflow repository'
[[ "${JOB_WORKFLOW_REF:-}" =~ ^[^@]+@[0-9a-f]{40}$ ]] || fail 'current caller must be immutable'
[[ "${JOB_WORKFLOW_REF%@*}" == "$WORKFLOW_REPOSITORY/.github/workflows/publish-manifests.yaml" ]] || fail 'unexpected current producer'
[[ "${SERVER_URL:-}" == https://github.com ]] || fail 'unsupported signature authority'
[[ -n "${ACTOR:-}" && -n "${GH_TOKEN:-}" ]] || fail 'missing registry credentials'
name="$(printf '%s' "${OCI_NAME:-$REPOSITORY}" | tr '[:upper:]' '[:lower:]')"
repository="$name/manifests"
[[ "$repository" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ && "${#repository}" -lt 256 ]] || fail 'invalid OCI repository'
artifact="$REGISTRY/$repository"
original_workflow="$WORKFLOW_REPOSITORY/.github/workflows/publish-manifests.yaml@$RECOVERY_WORKFLOW_SHA"
annotations=(
  -a "devantler.repository=$REPOSITORY"
  -a "devantler.source-sha=$SHA"
  -a "devantler.source-ref=$REF_NAME"
  -a "devantler.version=$VERSION"
  -a "devantler.run-id=$RECOVERY_RUN_ID"
  -a "devantler.run-attempt=$RECOVERY_RUN_ATTEMPT"
  -a "devantler.workflow-ref=$original_workflow"
)
cosign verify --certificate-identity "$SERVER_URL/$original_workflow" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com "${annotations[@]}" \
  "$artifact@$RECOVERY_DIGEST" >/dev/null || fail 'original signature or publication claims failed verification'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
accept='application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json'
read_version() {
  local status token observed
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
    --output "$work/manifest" --write-out '%{http_code}' \
    --header "Authorization: Bearer $token" --header "Accept: $accept" \
    "https://$REGISTRY/v2/$repository/manifests/$VERSION")" || fail 'registry version read failed'
  unset token
  case "$status" in
    200)
      observed="$(shasum -a 256 "$work/manifest" | cut -d ' ' -f1)" || fail 'manifest hashing failed'
      observed="sha256:$observed"
      [[ "$observed" == "$RECOVERY_DIGEST" ]] || fail 'version has a conflicting digest'
      printf 'matching\n' ;;
    404)
      jq -se 'length == 1 and (.[0] | type == "object" and (.errors | type == "array" and length > 0 and
        all(.[]; type == "object" and (.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN"))))' \
        "$work/manifest" >/dev/null 2>&1 || fail 'registry did not establish version absence'
      printf 'missing\n' ;;
    *) fail "registry version read returned HTTP $status" ;;
  esac
}
state="$(read_version)" || exit 1
if [[ "$state" == matching ]]; then
  echo 'Original signed version is already present; no tags changed.'
  exit 0
fi
# Registry V2 offers no compare-and-set. The workflow serializes cooperating
# publishers; readback detects other writers but cannot prevent their races.
flux tag artifact "oci://$artifact@$RECOVERY_DIGEST" --tag "$VERSION" --creds "$ACTOR:$GH_TOKEN"
[[ "$(read_version)" == matching ]] || fail 'recovered version is not present'
echo 'Original signed version recovered; latest is unchanged.'
