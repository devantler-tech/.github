#!/usr/bin/env bash
# Exercise the shipped publication step against an offline registry boundary.
# Signing/verification failure must not expose an unsigned semantic-version tag.
set -euo pipefail
# The live configuration caller must opt in only through a SHA-pinned publisher.
validate_caller() {
  yq -e '
  (.jobs["publish-manifests"].uses |
    test("^devantler-tech/actions/\\.github/workflows/publish-manifests\\.yaml@[0-9a-f]{40}$")) and
  (.jobs["publish-manifests"].with["enable-caller-pin"] == true) and
  (.jobs["publish-manifests"].with["enable-signed-promotion"] == true) and
  (.jobs["publish-manifests"].with["oci-name"] == "devantler-tech/github-config")
  ' "$1" >/dev/null
}
validate_caller .github/workflows/cd.yaml || {
  echo 'FAIL: configuration publication requires a SHA-pinned, verified-promotion caller' >&2
  exit 1
}
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"
workflow=.github/workflows/publish-manifests.yaml
step='📦 Sign & promote manifests artifact'
STEP="$step" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$workflow" >"$scratch/publish.sh"
[[ -s "$scratch/publish.sh" && "$(cat "$scratch/publish.sh")" != null ]] || {
  echo 'FAIL: missing production publication step' >&2
  exit 1
}
STEP='📦 Push & sign manifests artifact' yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$workflow" >"$scratch/legacy.sh"
# Bind the graph to complementary guards; GitHub evaluates them in hosted CI.
STEP="$step" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .if' "$workflow" >"$scratch/signed.if"
STEP='📦 Push & sign manifests artifact' yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .if' "$workflow" >"$scratch/legacy.if"
# shellcheck disable=SC2016 # literal GitHub expressions, never shell expansion
[[ "$(cat "$scratch/signed.if")" == '${{ inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == '\''true'\'' }}' ]]
# shellcheck disable=SC2016 # literal GitHub expressions, never shell expansion
[[ "$(cat "$scratch/legacy.if")" == '${{ !(inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == '\''true'\'') }}' ]]
digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
artifact=ghcr.io/devantler-tech/fixture/manifests
identity='https://github.com/devantler-tech/.github/.github/workflows/publish-manifests.yaml@0123456789abcdef0123456789abcdef01234567'
# Bind the exercised values to the actual workflow boundary, not a test-only input.
STEP="$step" yq -o=json '.jobs[].steps[] | select(.name == strenv(STEP)) | .env' "$workflow" |
  jq -e '
    .JOB_WORKFLOW_REF == "${{ steps.caller.outputs.ref }}" and
    .RUN_ID == "${{ github.run_id }}" and
    .RUN_ATTEMPT == "${{ github.run_attempt }}"
  ' >/dev/null || {
  echo 'FAIL: signed-promotion input wiring is missing' >&2
  exit 1
}
cat >"$scratch/bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s\n' "$*" >>"$STATE/calls"
case "$1 $2" in
  'push artifact')
    [[ "$FAIL_AT" != push ]] || exit 1
    printf '%s\n' "$3" >"$STATE/pushed"
    case "$3" in *:1.2.3 | *:1.2.3-rc.1) printf '%s\n' "$EXPECTED_DIGEST" >"$STATE/version" ;; esac
    if [[ "$FAIL_AT" == digest ]]; then printf '{"digest":"invalid"}\n'; else printf '{"digest":"%s"}\n' "$EXPECTED_DIGEST"; fi
    ;;
  'tag artifact')
    [[ "$4" == --tag ]] || exit 64
    [[ "$FAIL_AT" != version || "$5" == latest ]] || exit 1
    # The registry source must be the exact verified digest, not a mutable tag.
    if [[ "$SIGNED_PROMOTION" == true ]]; then
      [[ "$3" == "oci://$EXPECTED_ARTIFACT@$EXPECTED_DIGEST" ]] || exit 65
      [[ -f "$STATE/verified" ]] || { echo 'unsigned promotion' >&2; exit 66; }
    fi
    if [[ "$5" == latest ]]; then printf '%s\n' "$EXPECTED_DIGEST" >"$STATE/latest";
    else printf '%s\n' "$EXPECTED_DIGEST" >"$STATE/version"; fi
    ;;
  *) exit 67 ;;
esac
EOF
cat >"$scratch/bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cosign %s\n' "$*" >>"$STATE/calls"
case "$1" in
  sign)
    [[ "$2" == --yes && "$3" == "$EXPECTED_ARTIFACT@$EXPECTED_DIGEST" ]] || exit 68
    [[ "$FAIL_AT" != sign ]] || exit 1
    touch "$STATE/signed"
    ;;
  verify)
    [[ "$2" == --certificate-identity && "$3" == "$EXPECTED_IDENTITY" ]] || exit 69
    [[ "$4" == --certificate-oidc-issuer && "$5" == https://token.actions.githubusercontent.com ]] || exit 70
    [[ "$6" == "$EXPECTED_ARTIFACT@$EXPECTED_DIGEST" ]] || exit 71
    [[ -f "$STATE/signed" && "$FAIL_AT" != verify ]] || exit 1
    touch "$STATE/verified"
    ;;
  *) exit 72 ;;
esac
EOF
chmod +x "$scratch/bin/flux" "$scratch/bin/cosign"
fail() {
  echo "FAIL: $*" >&2
  cat "$scratch/out" "$state/calls" >&2
  exit 1
}
run_case() {
  local failure="$1" version="$2" flag="$3" caller="$4" run_id="$5"
  local script="$scratch/legacy.sh"
  [[ "$flag" != true ]] || script="$scratch/publish.sh"
  state="$(mktemp -d "$scratch/case.XXXXXX")"
  printf 'old-version\n' >"$state/version"
  printf 'old-latest\n' >"$state/latest"
  : >"$state/calls"
  PATH="$scratch/bin:$PATH" STATE="$state" FAIL_AT="$failure" \
    EXPECTED_DIGEST="$digest" EXPECTED_ARTIFACT="$artifact" EXPECTED_IDENTITY="$identity" \
    SIGNED_PROMOTION="$flag" ENABLE_SIGNED_PROMOTION="$flag" JOB_WORKFLOW_REF="$caller" \
    RUN_ID="$run_id" RUN_ATTEMPT=2 REGISTRY=ghcr.io OCI_NAME=devantler-tech/fixture \
    REPOSITORY=devantler-tech/fixture SERVER_URL=https://github.com VERSION="$version" \
    REF_NAME="v$version" SHA=0123456789abcdef0123456789abcdef01234567 DEPLOY_PATH=deploy \
    ACTOR=fixture GH_TOKEN=offline-fixture \
    bash "$script" >"$scratch/out" 2>&1
}
caller="${identity#https://github.com/}"
for failure in push digest sign verify version; do
  if run_case "$failure" 1.2.3 true "$caller" 123; then fail "succeeded after $failure failure"; fi
  [[ "$(<"$state/version")" == old-version && "$(<"$state/latest")" == old-latest ]] ||
    fail "$failure failure moved a consumer-selectable tag"
done
echo 'ok push, signing, verification and version-promotion failures leave release tags unchanged'
run_case none 1.2.3 true "$caller" 123 || fail 'stable release failed'
[[ "$(<"$state/version")" == "$digest" && "$(<"$state/latest")" == "$digest" ]] || fail 'stable tags were not promoted'
[[ "$(<"$state/pushed")" == "oci://$artifact:staging-123-2" ]] || fail 'push exposed a version tag before signing'
echo 'ok stable release promotes only the verified produced digest'
run_case none 1.2.3-rc.1 true "$caller" 123 || fail 'prerelease failed'
[[ "$(<"$state/version")" == "$digest" && "$(<"$state/latest")" == old-latest ]] || fail 'prerelease moved latest'
echo 'ok prerelease exposes its signed version without moving latest'
for caller in '' 'devantler-tech/.github/.github/workflows/publish-manifests.yaml@main'; do
  if run_case none 1.2.3 true "$caller" 123; then fail 'missing or mutable signer identity accepted'; fi
  [[ ! -s "$state/calls" ]] || fail 'bad signer identity wrote to registry'
done
if run_case none 1.2.3 true "${identity#https://github.com/}" invalid; then fail 'invalid staging identity accepted'; fi
[[ ! -s "$state/calls" ]] || fail 'invalid staging identity wrote to registry'
default_mode="$(yq -r '.on.workflow_call.inputs["enable-signed-promotion"].default' "$workflow")"
[[ "$default_mode" == false ]] || fail 'signed promotion must remain opt-in during migration'
run_case none 1.2.3 "$default_mode" '' 123 || fail 'legacy default changed'
[[ "$(<"$state/pushed")" == "oci://$artifact:1.2.3" && "$(<"$state/latest")" == "$digest" ]] || fail 'legacy publication changed'
echo 'ok default-off preserves existing callers; opted-in malformed identities fail before writes'

# Keep these controls in required CI, using the same predicate as the real caller.
for mutation in promotion pin moving family; do
  fixture="$scratch/caller-$mutation.yaml"
  cp .github/workflows/cd.yaml "$fixture"
  case "$mutation" in
    promotion) yq -i '.jobs["publish-manifests"].with["enable-signed-promotion"] = false' "$fixture" ;;
    pin) yq -i '.jobs["publish-manifests"].with["enable-caller-pin"] = false' "$fixture" ;;
    moving) yq -i '.jobs["publish-manifests"].uses |= sub("@[0-9a-f]{40}$"; "@main")' "$fixture" ;;
    family) yq -i '.jobs["publish-manifests"].uses |= sub("publish-manifests"; "publish-app")' "$fixture" ;;
  esac
  if validate_caller "$fixture" 2>/dev/null; then
    fail "configuration caller accepted the $mutation regression"
  fi
done
echo 'ok configuration caller refuses missing controls, moving refs and the wrong workflow family'
