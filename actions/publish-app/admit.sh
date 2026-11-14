#!/usr/bin/env bash
# Admit one release before anything reaches the registry.
#
# The keyless signature this action makes names the calling workflow at its ref, so only a
# complete semantic-version tag whose commit is already on the default branch may publish. Every
# input and manifest check also runs here, before login, so a refused release leaves the registry
# untouched. Nothing is echoed back until it has passed its own check.
set +x
set -euo pipefail
umask 077
export LC_ALL=C

fail() {
  echo "::error::publish-app refused the release: $*" >&2
  exit 1
}

catalogue="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
name='[A-Za-z0-9_-][A-Za-z0-9_.-]*'

check_inputs() {
  case "${MODE:-}" in
    deployment | prebuilt-webapp | manifests) ;;
    *) fail "mode must be deployment, prebuilt-webapp or manifests" ;;
  esac
  [[ -n "${GITHUB_OUTPUT:-}" ]] || fail 'missing step output file'
  [[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]{0,19}$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]{0,5}$ ]] ||
    fail 'require a numeric workflow run ID and attempt'
  [[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9_.-]{1,100}$ ]] ||
    fail 'invalid calling repository'
  [[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || fail 'require the tagged commit SHA'
  [[ -n "${GITHUB_ACTOR:-}" && -n "${GH_TOKEN:-}" ]] || fail 'missing registry credentials (github-token)'
  local prebuilt="${PREBUILT_IMAGE_DIGEST:-}${PREBUILT_PUBLIC_DIGEST:-}${PREBUILT_CI_RUN_ID:-}${PREBUILT_CI_RUN_ATTEMPT:-}"
  if [[ "$MODE" == manifests ]]; then
    [[ -z "${APP_NAME:-}" && -z "${APP_MANIFEST:-}" && -z "$prebuilt" ]] ||
      fail 'manifests mode takes no app-name, app-manifest or prebuilt-* input'
  else
    [[ "${APP_NAME:-}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
      fail 'app-name must be a DNS label (the container name, or the WebApp name in prebuilt mode)'
    [[ -z "${OCI_NAME:-}" ]] || fail 'oci-name applies only to manifests mode'
  fi
  if [[ "$MODE" == prebuilt-webapp ]]; then
    [[ "${PREBUILT_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail 'prebuilt-image-digest must be a sha256 digest'
    [[ "${PREBUILT_PUBLIC_DIGEST:-}" =~ ^[0-9a-f]{64}$ ]] || fail 'prebuilt-public-digest must be a SHA-256 hex digest'
    [[ "${PREBUILT_CI_RUN_ID:-}" =~ ^[1-9][0-9]{0,14}$ && "${PREBUILT_CI_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]{0,5}$ ]] ||
      fail 'prebuilt-ci-run-id and prebuilt-ci-run-attempt must be positive numbers'
  elif [[ -n "$prebuilt" ]]; then
    fail 'prebuilt-* inputs apply only to prebuilt-webapp mode'
  fi
}

# The ref must be refs/tags/v<SemVer 2.0.0>. Keep this identical to the tag step of the reusable
# publish workflows: Flux and docker/metadata-action must both be able to read and order it.
check_release_tag() {
  local ref="${GITHUB_REF:-}" num pre build semver numbers too_long
  [[ "$ref" == refs/tags/* ]] || fail 'publish-app must run on a release tag (refs/tags/v<semver>), not a branch or pull request ref'
  tag="${ref#refs/tags/}"
  num='(0|[1-9][0-9]*)'
  pre='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  build='[0-9A-Za-z-]+'
  semver="^v${num}\.${num}\.${num}(-${pre}(\.${pre})*)?(\+${build}(\.${build})*)?$"
  [[ "$tag" =~ $semver ]] || fail 'the release tag must be a complete semantic version vMAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]'
  # An OCI tag cannot carry `+`, and SemVer ignores build metadata when ordering versions.
  version="${tag#v}"
  version="${version%%+*}"
  numbers=".${version%%-*}."
  case "$version" in *-*) numbers="${numbers}${version#*-}." ;; esac
  too_long='\.[0-9]{16,}\.'
  if [[ "${#tag}" -gt 256 || "$numbers" =~ $too_long ]]; then
    fail "tag $tag must be at most 256 characters with numbers of at most 15 digits"
  fi
  [[ "${#version}" -le 128 ]] || fail "version $version is longer than the 128 characters an OCI tag allows"
}

# The certificate identity is the calling workflow at this tag. Require the workflow ref to name
# this repository and this exact tag, so the identity verified later is the caller's own.
check_signer_identity() {
  local ref="${GITHUB_WORKFLOW_REF:-}" prefix="${GITHUB_REPOSITORY}/.github/workflows/" file
  [[ "$ref" != *$'\n'* && "$ref" != *$'\r'* ]] || fail 'invalid calling workflow ref'
  [[ "$ref" == "$prefix"* && "$ref" == *"@$GITHUB_REF" ]] ||
    fail "the calling workflow must belong to $GITHUB_REPOSITORY and run on $GITHUB_REF"
  file="${ref#"$prefix"}"
  file="${file%"@$GITHUB_REF"}"
  [[ "$file" =~ ^${name}$ ]] || fail 'the calling workflow must be a file directly in .github/workflows'
}

check_checkout() {
  local head status=0
  head="$(git rev-parse --verify --quiet 'HEAD^{commit}')" ||
    fail 'check out the tagged commit (actions/checkout) at the workspace root before publish-app'
  [[ "$(git rev-parse --show-toplevel 2>/dev/null)" -ef . ]] ||
    fail 'check out the tagged commit at the workspace root (actions/checkout without a path)'
  [[ "$head" == "$GITHUB_SHA" ]] || fail "the checked-out commit is not the tagged commit $GITHUB_SHA"
  # A credential persisted by actions/checkout (its default) stays in the checkout, which is also the
  # image build context. Require persist-credentials: false.
  git config --local --includes --get-regexp '^http\..*\.extraheader$' >/dev/null || status=$?
  case "$status" in
    0) fail 'the checkout persisted a git credential; check out with persist-credentials: false' ;;
    1) ;;
    *) fail 'cannot inspect the checkout configuration' ;;
  esac
}

# The tagged commit must already be on the default branch. Fetch the remote's HEAD (its default
# branch) explicitly; anything that cannot be established refuses the release.
check_default_branch() {
  local url fetch_head tip status=0 retry
  url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}.git"
  retry="$catalogue/.scripts/retry.sh"
  fetch_head="$(git rev-parse --git-path FETCH_HEAD)" || fail 'cannot inspect the checkout'
  rm -f -- "$fetch_head"
  # The token travels in the environment for this one command, never on the command line.
  # The empty first value resets any inherited header list, so exactly one Authorization header is sent.
  if ! GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0="http.${GITHUB_SERVER_URL:-https://github.com}/.extraheader" GIT_CONFIG_VALUE_0='' \
    GIT_CONFIG_KEY_1="http.${GITHUB_SERVER_URL:-https://github.com}/.extraheader" \
    GIT_CONFIG_VALUE_1="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')" \
    bash "$retry" git fetch --quiet --no-tags --no-recurse-submodules "$url" HEAD; then
    fail "cannot determine whether $GITHUB_SHA is on the default branch: could not fetch the default branch"
  fi
  tip="$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}')" ||
    fail "cannot determine whether $GITHUB_SHA is on the default branch: no default branch commit was fetched"
  git merge-base --is-ancestor "$GITHUB_SHA" "$tip" || status=$?
  case "$status" in
    0) ;;
    1) fail "tag $tag points to $GITHUB_SHA, which is not on the default branch; tag a commit from the default branch" ;;
    *) fail "cannot determine whether $GITHUB_SHA is on the default branch (git exit $status)" ;;
  esac
}

# Walk <path> below $cursor one component at a time: plain names only, and no link anywhere.
walk() {
  local component components
  IFS=/ read -r -a components <<<"$1"
  for component in "${components[@]}"; do
    [[ "$component" =~ ^${name}$ ]] || fail "$2 must be plain names joined by /"
    cursor="$cursor/$component"
    [[ ! -L "$cursor" ]] || fail "$2 passes through a link"
  done
}

resolve_manifest() {
  local deploy="${DEPLOY_PATH:-}" manifest default
  [[ "$deploy" != *$'\n'* && "$deploy" != *$'\r'* ]] || fail 'deploy-path must not contain a line break'
  deploy="${deploy#./}"
  [[ -n "$deploy" && "$deploy" =~ ^${name}(/${name})*$ ]] ||
    fail "deploy-path must be a relative directory of plain names (no leading '/', no empty, '.' or '..' component)"
  cursor=.
  walk "$deploy" deploy-path
  [[ -d "$cursor" ]] || fail "deploy-path ./$deploy is not a directory"
  deploy_dir="$cursor"
  manifest_file=''
  [[ "$MODE" != manifests ]] || return 0
  default=deployment.yaml
  [[ "$MODE" != prebuilt-webapp ]] || default=webapp.yaml
  manifest="${APP_MANIFEST:-$default}"
  [[ "$manifest" =~ ^${name}(/${name})*$ ]] ||
    fail "app-manifest must be a relative path of plain names inside deploy-path (letters, digits, '.', '_' and '-'; no leading '/', no empty, '.' or '..' component)"
  walk "$manifest" app-manifest
  [[ -f "$cursor" ]] || fail "app manifest $cursor not found (check the deploy-path and app-manifest inputs)"
  manifest_file="$cursor"
  if [[ "$MODE" == deployment ]]; then
    local matches
    matches="$(APP_NAME="$APP_NAME" yq '[.spec.template.spec.containers[] | select(.name == strenv(APP_NAME))] | length' "$manifest_file")" ||
      fail "cannot read $manifest_file as a Deployment"
    [[ "$matches" == 1 ]] || fail "expected exactly one container named '$APP_NAME' in $manifest_file, found $matches"
  fi
}

# Everything under deploy-path is published, so it may hold only regular files and directories.
check_deploy_contents() {
  local unsafe
  unsafe="$(find "$deploy_dir" ! -type f ! -type d -print -quit)" || fail 'cannot inspect deploy-path'
  [[ -z "$unsafe" ]] || fail 'deploy-path must hold only regular files and directories (no links or special files)'
}

# The signed manifests must be the tagged source: nothing in deploy-path may differ from the tagged
# commit and nothing untracked (ignored files included) may sit in it. The rest of the workspace may
# hold build outputs.
check_deploy_source() {
  local status=0 untracked
  git diff --quiet --no-ext-diff --no-textconv HEAD -- "$deploy_dir" || status=$?
  case "$status" in
    0) ;;
    1) fail "deploy-path ${deploy_dir#./} differs from the tagged commit; publish only committed manifests" ;;
    *) fail 'cannot compare deploy-path with the tagged commit' ;;
  esac
  untracked="$(git ls-files --others -- "$deploy_dir")" || fail 'cannot list untracked files in deploy-path'
  [[ -z "$untracked" ]] || fail "deploy-path ${deploy_dir#./} holds files that are not in the tagged commit"
}

check_inputs
check_release_tag
check_signer_identity
check_checkout
check_default_branch
resolve_manifest
check_deploy_contents
check_deploy_source

owner="${GITHUB_REPOSITORY%%/*}"
repository="$(printf '%s' "$GITHUB_REPOSITORY" | tr '[:upper:]' '[:lower:]')"
oci="$repository"
if [[ -n "${OCI_NAME:-}" ]]; then
  oci="$(printf '%s' "$OCI_NAME" | tr '[:upper:]' '[:lower:]')"
  [[ "${oci%%/*}" == "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" ]] ||
    fail "oci-name must stay in the $owner namespace"
fi
segment='[a-z0-9]+([._-][a-z0-9]+)*'
[[ "$oci" =~ ^${segment}(/${segment})+$ && "${#oci}" -lt 240 ]] ||
  fail 'the OCI name is not a valid registry path; set oci-name in manifests mode'
image=''
staging_image=''
if [[ "$MODE" != manifests ]]; then
  image="ghcr.io/$oci"
  staging_image="$image:staging-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
fi
{
  printf 'version=%s\n' "$version"
  printf 'image=%s\n' "$image"
  printf 'staging-image=%s\n' "$staging_image"
  printf 'artifact=%s\n' "ghcr.io/$oci/manifests"
  printf 'deploy-path=%s\n' "$deploy_dir"
  printf 'manifest=%s\n' "$manifest_file"
} >>"$GITHUB_OUTPUT"
echo "Admitted $tag ($GITHUB_SHA, on the default branch) for $MODE publication as version $version."
