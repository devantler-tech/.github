#!/usr/bin/env bash
# Exercise the actual recovery command without granting registry write authority.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${1:-$root/.github/scripts/recover-manifests-version.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}' >"$work/manifest"
digest="sha256:$(shasum -a 256 "$work/manifest" | cut -d ' ' -f1)"
cat >"$work/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify\n' >>"$TRACE"
expected=(verify --certificate-identity https://github.com/devantler-tech/.github/.github/workflows/publish-manifests.yaml@0123456789abcdef0123456789abcdef01234567 --certificate-oidc-issuer https://token.actions.githubusercontent.com)
for claim in 'repository=devantler-tech/app' 'source-sha=fedcba9876543210fedcba9876543210fedcba98' 'source-ref=v1.2.3+build' 'version=1.2.3' 'run-id=123' 'run-attempt=2' 'workflow-ref=devantler-tech/.github/.github/workflows/publish-manifests.yaml@0123456789abcdef0123456789abcdef01234567'; do
  expected+=(-a "devantler.$claim")
done
expected+=("ghcr.io/devantler-tech/app/manifests@$RECOVERY_DIGEST")
[[ "$#" == "${#expected[@]}" ]] || exit 94
index=0
for argument in "$@"; do
  [[ "$argument" == "${expected[index]}" ]] || exit 95
  index=$((index + 1))
done
[[ "$SCENARIO" != signature ]] || exit 1
COSIGN
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$TRACE" && "$(head -1 "$TRACE")" == verify ]] || exit 90
output='' previous='' url=''
for arg in "$@"; do
  [[ "$previous" != --output ]] || output="$arg"
  case "$arg" in https://*) url="$arg" ;; esac
  previous="$arg"
done
[[ -n "$output" && "$*" == *'--proto =https'* && "$*" == *'--max-time 30'* && "$*" != *'--location'* ]] || exit 96
printf 'read\n' >>"$TRACE"
case "$url" in
  https://ghcr.io/token)
    [[ "$*" == *'--user fixture:synthetic-token'* && "$*" == *'scope=repository:devantler-tech/app/manifests:pull'* ]] || exit 97
    case "$SCENARIO" in
      auth) printf '{}' >"$output"; printf 403 ;;
      auth-partial) printf '{"token":"synthetic-bearer"}' >"$output"; exit 7 ;;
      auth-malformed) printf '{"token":"synthetic-bearer"}\n{}' >"$output"; printf 200 ;;
      *) printf '{"token":"synthetic-bearer"}' >"$output"; printf 200 ;;
    esac ;;
  https://ghcr.io/v2/devantler-tech/app/manifests/manifests/1.2.3)
    [[ "$*" == *'Authorization: Bearer synthetic-bearer'* ]] || exit 98
    case "$SCENARIO" in
      transport) cp "$MANIFEST" "$output"; exit 7 ;;
      forbidden) printf '{}' >"$output"; printf 403 ;;
      redirect) printf '{}' >"$output"; printf 302 ;;
      malformed) printf '{' >"$output"; printf 404 ;;
      mixed) printf '{"errors":[{"code":"MANIFEST_UNKNOWN"},{"code":"DENIED"}]}' >"$output"; printf 404 ;;
      conflict) printf '{}' >"$output"; printf 200 ;;
      matching) cp "$MANIFEST" "$output"; printf 200 ;;
      *)
        if [[ -f "$WRITTEN" ]]; then
          if [[ "$SCENARIO" == wrong-readback ]]; then printf '{}' >"$output"; else cp "$MANIFEST" "$output"; fi
          printf 200
        else printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404; fi ;;
    esac ;;
  *) exit 99 ;;
esac
CURL
cat >"$work/bin/flux" <<'FLUX'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "tag artifact oci://ghcr.io/devantler-tech/app/manifests@$RECOVERY_DIGEST --tag 1.2.3 --creds fixture:synthetic-token" ]] || exit 99
printf 'write\n' >>"$TRACE"
touch "$WRITTEN"
[[ "$SCENARIO" != interrupted ]] || exit 1
FLUX
chmod +x "$work/bin/"*
run() {
  local scenario="$1"
  shift
  env -i PATH="$work/bin:$PATH" TRACE="$work/trace" MANIFEST="$work/manifest" WRITTEN="$work/written" SCENARIO="$scenario" \
    REGISTRY=ghcr.io ACTOR=fixture GH_TOKEN=synthetic-token OCI_NAME='' REPOSITORY=devantler-tech/app \
    SHA=fedcba9876543210fedcba9876543210fedcba98 REF_NAME=v1.2.3+build VERSION=1.2.3 SERVER_URL=https://github.com \
    WORKFLOW_REPOSITORY=devantler-tech/.github JOB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/publish-manifests.yaml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    RECOVERY_DIGEST="$digest" RECOVERY_RUN_ID=123 RECOVERY_RUN_ATTEMPT=2 RECOVERY_WORKFLOW_SHA=0123456789abcdef0123456789abcdef01234567 \
    ENABLE_SIGNED_PROMOTION=true ENABLE_CALLER_PIN=true "$@" bash "$script" >"$work/log" 2>&1
}
for scenario in missing matching signature auth auth-partial auth-malformed transport forbidden redirect malformed mixed conflict wrong-readback interrupted; do
  : >"$work/trace"
  rm -f "$work/written"
  status=0
  # Scenario is carried once as environment data, never as a command.
  env_scenario="$scenario"
  run "$env_scenario" env || status=$?
  case "$scenario" in
    missing) [[ "$status" == 0 && "$(grep -c '^write$' "$work/trace")" == 1 ]] || { cat "$work/log"; echo 'FAIL: missing tag was not recovered'; exit 1; } ;;
    matching) if [[ "$status" != 0 ]] || grep -q '^write$' "$work/trace"; then echo 'FAIL: matching tag was written'; exit 1; fi ;;
    wrong-readback|interrupted) [[ "$status" != 0 ]] || { echo 'FAIL: incomplete publication succeeded'; exit 1; } ;;
    *) if [[ "$status" == 0 ]] || grep -q '^write$' "$work/trace"; then echo "FAIL: $scenario authorized recovery"; exit 1; fi ;;
  esac
  ! grep -Eq 'synthetic-token|synthetic-bearer' "$work/log" || { echo 'FAIL: credentials printed'; exit 1; }
done
rm -f "$work/written"
: >"$work/trace"
if run interrupted env; then echo 'FAIL: interrupted tagging succeeded'; exit 1; fi
run missing env
[[ "$(grep -c '^write$' "$work/trace")" == 1 ]] || { echo 'FAIL: interrupted recovery retry wrote again'; exit 1; }
for assignment in ENABLE_SIGNED_PROMOTION=false ENABLE_CALLER_PIN=false RECOVERY_WORKFLOW_SHA=main RECOVERY_RUN_ID=wrong RECOVERY_RUN_ATTEMPT=wrong RECOVERY_DIGEST=sha256:bad; do
  : >"$work/trace"
  if run missing env "$assignment"; then echo "FAIL: invalid $assignment accepted"; exit 1; fi
  [[ ! -s "$work/trace" ]] || { echo 'FAIL: invalid recovery reached an external command'; exit 1; }
done
# Bind the helper to its hosted admission, immutable source and exclusive mode.
workflow="$root/.github/workflows/publish-manifests.yaml"
yq -o=json '.' "$workflow" | jq -e '
  .jobs["publish-manifests"].steps as $steps |
  .on.workflow_call.inputs["enable-signed-recovery"].default == false and
  ($steps | map(select(.name == "🔒 Admit explicit recovery")) | length == 1) and
  ($steps | map(select(.name == "🔏 Recover original manifests version")) | length == 1) and
  ($steps | map(select(.name == "🔏 Recover original manifests version"))[0] |
    .if == "${{ inputs.enable-signed-recovery }}" and
    .env.RECOVERY_DIGEST == "${{ inputs.recovery-digest }}" and
    .env.RECOVERY_RUN_ID == "${{ inputs.recovery-run-id }}" and
    .env.RECOVERY_RUN_ATTEMPT == "${{ inputs.recovery-run-attempt }}" and
    .env.RECOVERY_WORKFLOW_SHA == "${{ inputs.recovery-workflow-sha }}" and
    .env.JOB_WORKFLOW_REF == "${{ steps.caller.outputs.ref }}" and
    .env.WORKFLOW_REPOSITORY == "${{ job.workflow_repository }}" and
    .env.REPOSITORY == "${{ github.repository }}" and
    .env.SHA == "${{ github.sha }}" and
    .env.REF_NAME == "${{ github.ref_name }}" and
    .env.VERSION == "${{ steps.version.outputs.version }}" and
    .env.SERVER_URL == "${{ github.server_url }}" and
    .env.ENABLE_SIGNED_PROMOTION == "${{ inputs.enable-signed-promotion }}" and
    .env.ENABLE_CALLER_PIN == "${{ inputs.enable-caller-pin }}" and
    .run == "bash \"$RUNNER_TEMP/recover-manifests-version.sh\"")
' >/dev/null || { echo 'FAIL: recovery workflow boundary changed'; exit 1; }
echo 'PASS: authenticated missing/matching tags, conflicting bytes, partial reads, write failures and required recovery inputs'
