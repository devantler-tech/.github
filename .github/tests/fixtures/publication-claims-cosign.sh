#!/usr/bin/env bash
# Offline cosign boundary for extracted production publication steps.
set -euo pipefail
mode="$1"
shift
kind=manifest
if [[ -n "${IMAGE_DIGEST:-}" ]]; then
  kind=image
  [[ "${!#}" != *'/manifests@'* ]] || kind=manifest
fi
state="${STATE:?}"
fault="${FAULT:-${FAIL_AT:-none}}"
trace="${TRACE:-$state/calls}"
printf 'cosign %s %s\n' "$mode" "$*" >>"$trace"
[[ "$fault" != "$mode" && "$fault" != "$kind-$mode" ]] || exit 23
identity="${EXPECTED_IDENTITY:-https://github.com/devantler-tech/.github/.github/workflows/publish-app.yaml@0123456789abcdef0123456789abcdef01234567}"
claims=()
yes=false
target=''
identity_seen=false
issuer_seen=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --yes) yes=true; shift ;;
    -a) [[ "$#" -ge 2 ]] || exit 64; claims+=("$2"); shift 2 ;;
    --certificate-identity) [[ "$#" -ge 2 && "$2" == "$identity" ]] || exit 65; identity_seen=true; shift 2 ;;
    --certificate-oidc-issuer) [[ "$#" -ge 2 && "$2" == https://token.actions.githubusercontent.com ]] || exit 66; issuer_seen=true; shift 2 ;;
    --*) echo 'claims: unknown cosign option' >&2; exit 67 ;;
    *) [[ -z "$target" ]] || exit 68; target="$1"; shift ;;
  esac
done
[[ "$mode" != sign || "$yes" == true ]] || exit 69
[[ "$mode" != verify || ( "$identity_seen" == true && "$issuer_seen" == true ) ]] || exit 69
if [[ -n "${IMAGE_DIGEST:-}" ]]; then
  expected_target="ghcr.io/devantler-tech/app@$IMAGE_DIGEST"
  [[ "$kind" != manifest ]] || expected_target="ghcr.io/devantler-tech/app/manifests@$MANIFEST_DIGEST"
else
  expected_target="$EXPECTED_ARTIFACT@$EXPECTED_DIGEST"
fi
[[ "$target" == "$expected_target" ]] || exit 70
if [[ "${SIGNED_PROMOTION:-true}" == false ]]; then
  [[ "$mode" == sign && "${#claims[@]}" == 0 ]] || exit 71
  touch "$state/signed"
  exit 0
fi
expected=(
  "devantler.repository=$REPOSITORY"
  "devantler.source-sha=$SHA"
  "devantler.source-ref=$REF_NAME"
  "devantler.version=$VERSION"
  "devantler.run-id=$RUN_ID"
  "devantler.run-attempt=$RUN_ATTEMPT"
  "devantler.workflow-ref=$JOB_WORKFLOW_REF"
)
if [[ -n "${IMAGE_DIGEST:-}" ]]; then
  expected+=("devantler.image-digest=$IMAGE_DIGEST" "devantler.manifests-digest=$MANIFEST_DIGEST")
fi
printf '%s\n' "${claims[@]}" >"$state/actual-claims"
printf '%s\n' "${expected[@]}" >"$state/expected-claims"
LC_ALL=C sort "$state/actual-claims" >"$state/actual-sorted"
LC_ALL=C sort "$state/expected-claims" >"$state/expected-sorted"
cmp -s "$state/actual-sorted" "$state/expected-sorted" || {
  echo 'claims: missing, duplicate or conflicting publication claim' >&2
  exit 72
}
case "$mode" in
  sign)
    cp "$state/actual-sorted" "$state/$kind-claims"
    if [[ "$fault" == claim-$kind-* ]]; then
      key="${fault#claim-"$kind"-}"
      awk -v key="$key" 'index($0,key "=")==1 {print key "=wrong"; next} {print}' \
        "$state/$kind-claims" >"$state/corrupt-claims"
      mv "$state/corrupt-claims" "$state/$kind-claims"
    fi
    touch "$state/signed"
    ;;
  verify)
    cmp -s "$state/$kind-claims" "$state/actual-sorted" || {
      echo 'claims: signed payload mismatch' >&2
      exit 73
    }
    touch "$state/verified" "$state/$kind-verified"
    ;;
  *) exit 74 ;;
esac
