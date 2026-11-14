#!/usr/bin/env bash
# Refuse a release version that already exists in any repository this release writes to. Only an
# authenticated, definitive absence passes (see .github/scripts/require-unpublished-version.sh).
set +x
set -euo pipefail
catalogue="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "${ARTIFACT:-}" == ghcr.io/* ]] || { echo '::error::publish-app: missing manifests artifact name' >&2; exit 1; }
repositories="${ARTIFACT#ghcr.io/}"
if [[ -n "${IMAGE:-}" ]]; then
  [[ "$IMAGE" == ghcr.io/* ]] || { echo '::error::publish-app: invalid image name' >&2; exit 1; }
  repositories="$(printf '%s\n%s' "${IMAGE#ghcr.io/}" "$repositories")"
fi
REGISTRY=ghcr.io ACTOR="${GITHUB_ACTOR:-}" OCI_REPOSITORIES="$repositories" \
  bash "$catalogue/.github/scripts/require-unpublished-version.sh"
