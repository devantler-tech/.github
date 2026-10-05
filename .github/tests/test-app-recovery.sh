#!/usr/bin/env bash
# Execute paired recovery with controlled external failures and exclusive workflow admission.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$root/.github/workflows/publish-app.yaml"
fail() { echo "app-recovery: $*" >&2; exit 1; }
yq -o=json '.' "$workflow" | jq -e '
  .on.workflow_call.inputs as $inputs |
  $inputs["enable-signed-recovery"].default == false and
  (["recovery-image-digest", "recovery-manifests-digest", "recovery-run-id", "recovery-run-attempt", "recovery-workflow-sha"] |
    all(. as $name | $inputs[$name].type == "string" and $inputs[$name].default == "" and $inputs[$name].required == false)) and
  (.jobs.publish.steps | map(select(.name == "🔏 Recover original application version")) | length == 1)
' >/dev/null || fail 'default-off paired recovery is absent'
# A recovery request cannot reach normal artifact creation or signing.
# shellcheck disable=SC2016 # Literal GitHub expressions are the admission contract.
yq -o=json '.' "$workflow" | jq -e '
  .jobs.publish.steps as $steps |
  (["🔍 Validate the deployment manifest", "🏷️ Derive image tags", "🐳 Build & push image", "📌 Pin image digest in manifests"] |
    all(. as $name | ($steps | map(select(.name == $name)) | length == 1) and
      ($steps | map(select(.name == $name))[0].if == "${{ !inputs.enable-signed-recovery }}"))) and
  (["🔒 Prepare signed image staging", "📦 Sign & promote image and manifests"] |
    all(. as $name | ($steps | map(select(.name == $name))[0].if == "${{ !inputs.enable-signed-recovery && (inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == '\''true'\'') }}"))) and
  ($steps | map(select(.name == "🔏 Recover original application version"))[0] |
    .if == "${{ inputs.enable-signed-recovery }}" and
    .env.RECOVERY_IMAGE_DIGEST == "${{ inputs.recovery-image-digest }}" and
    .env.RECOVERY_MANIFESTS_DIGEST == "${{ inputs.recovery-manifests-digest }}" and
    .env.RECOVERY_RUN_ID == "${{ inputs.recovery-run-id }}" and
    .env.RECOVERY_RUN_ATTEMPT == "${{ inputs.recovery-run-attempt }}" and
    .env.RECOVERY_WORKFLOW_SHA == "${{ inputs.recovery-workflow-sha }}" and
    .env.JOB_WORKFLOW_REF == "${{ steps.caller.outputs.ref }}" and
    .env.WORKFLOW_REPOSITORY == "${{ job.workflow_repository }}" and
    .env.REPOSITORY == "${{ github.repository }}" and .env.SHA == "${{ github.sha }}" and
    .env.REF_NAME == "${{ github.ref_name }}" and .env.VERSION == "${{ steps.version.outputs.version }}" and
    .env.SERVER_URL == "${{ github.server_url }}" and
    .env.ENABLE_SIGNED_PROMOTION == "${{ inputs.enable-signed-promotion }}" and
    .env.ENABLE_CALLER_PIN == "${{ inputs.enable-caller-pin }}" and
    .run == "bash \"$RUNNER_TEMP/recover-app-version.sh\"")
' >/dev/null || fail 'recovery routing or source binding is unsafe'
prepare="$(yq -r '.jobs.publish.steps[] | select(.name == "🔒 Prepare immutable publication guard") | .run' "$workflow")"
# shellcheck disable=SC2016 # Match the runner variable literally in the shipped step.
grep -qxF 'cp .devantler-tech-publisher/.github/scripts/recover-app-version.sh "$RUNNER_TEMP/recover-app-version.sh"' <<<"$prepare" || fail 'recovery helper is not copied from immutable publisher checkout'
grep -qxF 'rm -rf -- .devantler-tech-publisher' <<<"$prepare" || fail 'publisher helpers remain in the consumer build context'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
yq -r '.jobs.publish.steps[] | select(.name == "🔒 Admit explicit recovery") | .run' "$workflow" >"$work/admit.sh"
for promotion in true false; do
  for pin in true false; do
    status=0
    ENABLE_SIGNED_PROMOTION="$promotion" ENABLE_CALLER_PIN="$pin" bash -euo pipefail "$work/admit.sh" >"$work/log" 2>&1 || status=$?
    if [[ "$promotion" == true && "$pin" == true ]]; then [[ "$status" == 0 ]]; else [[ "$status" != 0 ]]; fi
  done
done
printf '{"schemaVersion":2,"manifests":[]}' >"$work/image"
printf '{"schemaVersion":2,"manifests":[],"annotations":{"fixture":"manifests"}}' >"$work/manifests"
image_digest="sha256:$(shasum -a 256 "$work/image" | cut -d ' ' -f1)"
manifests_digest="sha256:$(shasum -a 256 "$work/manifests" | cut -d ' ' -f1)"
cat >"$work/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
kind=image
[[ "${!#}" != *'/manifests@'* ]] || kind=manifests
printf 'verify-%s\n' "$kind" >>"$TRACE"
expected=(verify --certificate-identity https://github.com/devantler-tech/.github/.github/workflows/publish-app.yaml@0123456789abcdef0123456789abcdef01234567 --certificate-oidc-issuer https://token.actions.githubusercontent.com)
for claim in 'repository=devantler-tech/app' 'source-sha=fedcba9876543210fedcba9876543210fedcba98' 'source-ref=v1.2.3+proof' "version=$VERSION" 'run-id=123' 'run-attempt=2' 'workflow-ref=devantler-tech/.github/.github/workflows/publish-app.yaml@0123456789abcdef0123456789abcdef01234567' "image-digest=$RECOVERY_IMAGE_DIGEST" "manifests-digest=$RECOVERY_MANIFESTS_DIGEST"; do expected+=(-a "devantler.$claim"); done
target="ghcr.io/devantler-tech/app@$RECOVERY_IMAGE_DIGEST"
[[ "$kind" != manifests ]] || target="ghcr.io/devantler-tech/app/manifests@$RECOVERY_MANIFESTS_DIGEST"
expected+=("$target")
[[ "$#" == "${#expected[@]}" ]] || exit 94
index=0
for arg in "$@"; do [[ "$arg" == "${expected[index]}" ]] || exit 95; index=$((index + 1)); done
[[ "$SCENARIO" != "signature-$kind" ]] || exit 1
COSIGN
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(head -2 "$TRACE")" == $'verify-image\nverify-manifests' ]] || exit 90
output='' previous='' url='' kind=image
for arg in "$@"; do
  [[ "$previous" != --output ]] || output="$arg"
  case "$arg" in https://*) url="$arg" ;; scope=repository:*/manifests:pull) kind=manifests ;; esac
  previous="$arg"
done
[[ -n "$output" && "$*" == *'--proto =https'* && "$*" == *'--max-time 30'* && "$*" != *'--location'* ]] || exit 96
if [[ "$url" == https://ghcr.io/token ]]; then
  [[ "$*" == *'--user fixture:synthetic-token'* ]] || exit 97
  printf 'auth-%s\n' "$kind" >>"$TRACE"
  printf '{"token":"synthetic-bearer"}' >"$output"
  [[ "$SCENARIO" != auth-partial ]] || exit 7
  printf 200
  exit
fi
[[ "$*" == *'Authorization: Bearer synthetic-bearer'* ]] || exit 98
[[ "$url" != *'/app/manifests/manifests/'* ]] || kind=manifests
[[ "$url" == "https://ghcr.io/v2/devantler-tech/app/manifests/$VERSION" || "$url" == "https://ghcr.io/v2/devantler-tech/app/manifests/manifests/$VERSION" ]] || exit 99
printf 'read-%s\n' "$kind" >>"$TRACE"
case "$SCENARIO" in
  partial-*) [[ "$SCENARIO" != "partial-$kind" ]] || { cp "$STATE/$kind" "$output"; exit 7; } ;;
  forbidden-*) [[ "$SCENARIO" != "forbidden-$kind" ]] || { printf '{}' >"$output"; printf 403; exit; } ;;
  redirect-*) [[ "$SCENARIO" != "redirect-$kind" ]] || { printf '{}' >"$output"; printf 302; exit; } ;;
  mixed-*) [[ "$SCENARIO" != "mixed-$kind" ]] || { printf '{"errors":[{"code":"MANIFEST_UNKNOWN"},{"code":"DENIED"}]}' >"$output"; printf 404; exit; } ;;
esac
if [[ -e "$STATE/present-$kind" ]]; then
  if [[ "$SCENARIO" == "conflict-$kind" || "$SCENARIO" == "readback-$kind" ]]; then printf '{}' >"$output"; else cp "$STATE/$kind" "$output"; fi
  printf 200
else printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404; fi
CURL
cat >"$work/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "buildx imagetools create --prefer-index=false --tag ghcr.io/devantler-tech/app:$VERSION ghcr.io/devantler-tech/app@$RECOVERY_IMAGE_DIGEST" ]] || exit 99
grep -qx read-image "$TRACE"
grep -qx read-manifests "$TRACE"
printf 'write-image\n' >>"$TRACE"
touch "$STATE/present-image"
[[ "$SCENARIO" != interrupted-image ]] || exit 1
DOCKER
cat >"$work/bin/flux" <<'FLUX'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "tag artifact oci://ghcr.io/devantler-tech/app/manifests@$RECOVERY_MANIFESTS_DIGEST --tag $VERSION --creds fixture:synthetic-token" ]] || exit 99
grep -qx read-image "$TRACE"
grep -qx read-manifests "$TRACE"
printf 'write-manifests\n' >>"$TRACE"
touch "$STATE/present-manifests"
[[ "$SCENARIO" != interrupted-manifests ]] || exit 1
FLUX
chmod +x "$work/bin/"*
run() {
  local scenario="$1"
  shift
  env -i PATH="$work/bin:$PATH" TRACE="$work/trace" STATE="$work" SCENARIO="$scenario" \
    REGISTRY=ghcr.io ACTOR=fixture GH_TOKEN=synthetic-token IMAGE_NAME=devantler-tech/app REPOSITORY=devantler-tech/app \
    SHA=fedcba9876543210fedcba9876543210fedcba98 REF_NAME=v1.2.3+proof VERSION=1.2.3 SERVER_URL=https://github.com \
    WORKFLOW_REPOSITORY=devantler-tech/.github JOB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/publish-app.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    RECOVERY_IMAGE_DIGEST="$image_digest" RECOVERY_MANIFESTS_DIGEST="$manifests_digest" RECOVERY_RUN_ID=123 RECOVERY_RUN_ATTEMPT=2 RECOVERY_WORKFLOW_SHA=0123456789abcdef0123456789abcdef01234567 \
    ENABLE_SIGNED_PROMOTION=true ENABLE_CALLER_PIN=true "$@" bash "$root/.github/scripts/recover-app-version.sh" >"$work/log" 2>&1
}
for scenario in missing matching image-only manifests-only signature-image signature-manifests auth-partial partial-image partial-manifests forbidden-image forbidden-manifests redirect-image redirect-manifests mixed-image mixed-manifests conflict-image conflict-manifests readback-image readback-manifests interrupted-image interrupted-manifests; do
  : >"$work/trace"
  rm -f "$work/present-image" "$work/present-manifests"
  case "$scenario" in
    matching) touch "$work/present-image" "$work/present-manifests" ;;
    image-only|conflict-image) touch "$work/present-image" ;;
    manifests-only|conflict-manifests) touch "$work/present-manifests" ;;
  esac
  status=0
  run "$scenario" env || status=$?
  count="$(grep -c '^write-' "$work/trace" || true)"
  case "$scenario" in
    missing) [[ "$status" == 0 && "$count" == 2 ]] || { cat "$work/log"; fail 'missing pair not restored'; } ;;
    matching) [[ "$status" == 0 && "$count" == 0 ]] || fail 'matching pair changed' ;;
    image-only|manifests-only) [[ "$status" == 0 && "$count" == 1 ]] || fail 'partial pair not restored' ;;
    readback-*|interrupted-*) [[ "$status" != 0 ]] || fail 'incomplete publication succeeded' ;;
    *) [[ "$status" != 0 && "$count" == 0 ]] || fail "$scenario authorized a write" ;;
  esac
  ! grep -Eq 'synthetic-token|synthetic-bearer' "$work/log" || fail 'credentials printed'
done
for scenario in interrupted-image interrupted-manifests; do
  rm -f "$work/present-image" "$work/present-manifests"
  : >"$work/trace"
  if run "$scenario" env; then fail 'interrupted write succeeded'; fi
  : >"$work/trace"
  run missing env || { cat "$work/log"; fail 'interrupted pair could not resume'; }
  count="$(grep -c '^write-' "$work/trace" || true)"
  if [[ "$scenario" == interrupted-image ]]; then [[ "$count" == 1 ]]; else [[ "$count" == 0 ]]; fi
done
for assignment in ENABLE_SIGNED_PROMOTION=false ENABLE_CALLER_PIN=false RECOVERY_WORKFLOW_SHA=main RECOVERY_RUN_ID=wrong RECOVERY_RUN_ATTEMPT=wrong RECOVERY_IMAGE_DIGEST=sha256:bad RECOVERY_MANIFESTS_DIGEST=sha256:bad; do
  : >"$work/trace"
  if run missing env "$assignment"; then fail "invalid $assignment accepted"; fi
  [[ ! -s "$work/trace" ]] || fail 'invalid admission reached an external command'
done
echo 'PASS: paired missing/matching/partial recovery, both signature and observation failures, conflicts, interrupted writes and idempotent retries'
