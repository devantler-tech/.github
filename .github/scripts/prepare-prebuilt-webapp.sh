#!/usr/bin/env bash
# Verify the public main-CI image contract before changing a source-owned WebApp.
# This helper makes no registry writes and never executes the candidate image.
set -euo pipefail
export LC_ALL=C
fail() {
  echo "::error::prebuilt WebApp verification failed: $1" >&2
  exit 1
}
[[ "${REPOSITORY:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}$ ]] || fail 'invalid caller repository'
[[ "${REPOSITORY#*/}" != . && "${REPOSITORY#*/}" != .. ]] || fail 'invalid caller repository'
[[ "${SOURCE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'require the caller source commit'
[[ "${APP_NAME:-}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || fail 'require a DNS-label application name'
[[ "${PREBUILT_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'require an immutable image digest'
[[ "${PREBUILT_PUBLIC_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]] || fail 'require the public artifact digest'
[[ "${PREBUILT_CI_RUN_ID:-}" =~ ^[1-9][0-9]{0,14}$ && "${PREBUILT_CI_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]{0,5}$ ]] || fail 'require bounded positive original CI run and attempt'
[[ -n "${GITHUB_OUTPUT:-}" ]] || fail 'missing workflow output file'
path="${DEPLOY_PATH#./}"
[[ -n "$path" && "$path" != /* && "$path" != */ && "$path" != *//* ]] || fail 'require a relative deployment directory'
cursor=.
IFS=/ read -r -a components <<< "$path"
for component in "${components[@]}"; do
  [[ "$component" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ && "$component" != . && "$component" != .. ]] || fail 'unsafe deployment directory'
  cursor="$cursor/$component"
  [[ -d "$cursor" && ! -L "$cursor" ]] || fail 'deployment directories must be regular source directories'
done
file="$cursor/webapp.yaml"
[[ -f "$file" && ! -L "$file" ]] || fail 'require a regular webapp.yaml'
unsafe="$(find "$cursor" ! -type f ! -type d -print -quit)" || fail 'cannot inspect the complete deployment directory'
[[ -z "$unsafe" ]] || fail 'deployment artifacts cannot contain linked or special files'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# A complete parse precedes all observations and mutations. Keep unrelated documents.
yq -o=json -I=0 '.' "$file" > "$work/documents.json" || fail 'manifest cannot be parsed'
jq -se --arg name "$APP_NAME" '
  [.[] | select(.apiVersion == "kro.run/v1alpha1" and .kind == "WebApp")] as $apps |
  ($apps | length) == 1 and
  ($apps[0] | .metadata.name == $name and .metadata.namespace == $name and
    .spec.name == $name and (.spec.image | type) == "string" and (.spec.image | length) > 0)
' "$work/documents.json" > /dev/null || fail 'require exactly one matching WebApp name, namespace and image'
image="ghcr.io/$(printf '%s' "$REPOSITORY" | tr '[:upper:]' '[:lower:]')"
ref="$image@$PREBUILT_IMAGE_DIGEST"
identity="https://github.com/$REPOSITORY/.github/workflows/ci.yaml@refs/heads/main"
run_url="https://api.github.com/repos/$REPOSITORY/actions/runs/$PREBUILT_CI_RUN_ID"

read_run() {
  # Deliberately credential-free. Private or inaccessible source CI is unsupported.
  curl -q --fail --silent --show-error --connect-timeout 10 --max-time 20 --max-filesize 1048576 --proto '=https' \
    -H 'Accept: application/vnd.github+json' "$1" > "$work/run.json" || fail 'cannot read complete public CI evidence'
  jq -se --arg repo "$REPOSITORY" --arg sha "$SOURCE_SHA" --arg run "$PREBUILT_CI_RUN_ID" --arg attempt "$PREBUILT_CI_RUN_ATTEMPT" '
    length == 1 and (.[0] |
    .id == ($run | tonumber) and .run_attempt == ($attempt | tonumber) and
    .repository.full_name == $repo and .head_repository.full_name == $repo and
    .head_sha == $sha and .head_branch == "main" and .path == ".github/workflows/ci.yaml" and
    .event == "push" and .status == "completed" and .conclusion == "success")
  ' "$work/run.json" > /dev/null || fail 'original CI source, attempt or success does not match'
}
read_run "$run_url"
read_run "$run_url/attempts/$PREBUILT_CI_RUN_ATTEMPT"
annotations=(
  -a "devantler.repository=$REPOSITORY"
  -a "devantler.source-sha=$SOURCE_SHA"
  -a "devantler.public-digest=$PREBUILT_PUBLIC_DIGEST"
  -a devantler.public-profile=production-template
  -a "devantler.ci-run-id=$PREBUILT_CI_RUN_ID"
  -a "devantler.ci-run-attempt=$PREBUILT_CI_RUN_ATTEMPT"
  -a "devantler.run-id=$PREBUILT_CI_RUN_ID"
  -a "devantler.run-attempt=$PREBUILT_CI_RUN_ATTEMPT"
  -a "devantler.workflow-sha=$SOURCE_SHA"
)
cosign verify --certificate-identity "$identity" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "${annotations[@]}" "$ref" > "$work/signature.json" || fail 'original image signature or claims do not verify'
jq -se --arg ref "$ref" --arg digest "$PREBUILT_IMAGE_DIGEST" '
  length == 1 and (.[0] | type == "array" and length > 0 and all(.[];
    .critical.identity["docker-reference"] == $ref and
    .critical.image["docker-manifest-digest"] == $digest))
' "$work/signature.json" > /dev/null || fail 'verified signature has a different image subject'
cosign verify-attestation --type slsaprovenance --certificate-identity "$identity" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "$ref" > "$work/attestation.json" || fail 'original provenance does not verify'
jq -es --arg identity "$identity" --arg image "$image" --arg digest "${PREBUILT_IMAGE_DIGEST#sha256:}" \
  --arg source "$SOURCE_SHA" --arg repo "$REPOSITORY" --arg run "$PREBUILT_CI_RUN_ID" \
  --arg attempt "$PREBUILT_CI_RUN_ATTEMPT" --arg public "$PREBUILT_PUBLIC_DIGEST" '
  [.[] | .payload | @base64d | fromjson] as $statements |
  ($statements | length) > 0 and all($statements[];
    .predicateType == "https://slsa.dev/provenance/v0.2" and
    .subject == [{name:$image,digest:{sha256:$digest}}] and
    .predicate.builder.id == $identity and
    .predicate.buildType == "https://devantler.tech/build-types/combined-runtime-container/v1" and
    .predicate.invocation.configSource == {
      uri:("git+https://github.com/" + $repo),digest:{sha1:$source},entryPoint:".github/workflows/ci.yaml"} and
    .predicate.invocation.parameters == {
      ciRunId:$run,ciRunAttempt:$attempt,publicDigest:$public,publicProfile:"production-template"} and
    .predicate.materials == [{uri:("git+https://github.com/" + $repo),digest:{sha1:$source}}] and
    .predicate.metadata.buildInvocationId == ("https://github.com/" + $repo + "/actions/runs/" + $run)
  )
' "$work/attestation.json" > /dev/null || fail 'signed provenance does not bind the exact source, build and public artifact'
# A newer rerun must not silently replace the completed attempt during verification.
read_run "$run_url"
PREBUILT_IMAGE="$ref" yq -i '
  (select(.apiVersion == "kro.run/v1alpha1" and .kind == "WebApp") | .spec.image) = strenv(PREBUILT_IMAGE)
' "$file" || fail 'cannot pin the verified image'
yq -o=json -I=0 '.' "$file" > "$work/pinned.json" || fail 'cannot read back pinned manifests'
jq -s --arg image "$ref" '
  map(if .apiVersion == "kro.run/v1alpha1" and .kind == "WebApp" then .spec.image = $image else . end)
' "$work/documents.json" > "$work/expected.json"
jq -s '.' "$work/pinned.json" > "$work/actual.json"
cmp -s "$work/expected.json" "$work/actual.json" || fail 'pin readback changed other manifest data'
{
  printf 'digest=%s\n' "$PREBUILT_IMAGE_DIGEST"
  printf 'public-digest=%s\n' "$PREBUILT_PUBLIC_DIGEST"
} >> "$GITHUB_OUTPUT"
