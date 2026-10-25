#!/usr/bin/env bash
# Download the scanned module's dependencies before the scan, through the shared
# bounded retry, so a transient module-proxy or network error is retried instead
# of failing as if the scan had. Only this download is retried: the scan that
# follows still runs once, so a finding is never retried. Paths are relative to
# the checkout, except the absolute retry helper.
set -euo pipefail
module="$1" retry="$2"
cd "$module"
# Skip only when Go itself loads every scanned package with the network off.
# Go, not this script, then decides vendoring, workspaces, -mod flags and the cache.
if GOPROXY=off go list -deps ./... >/dev/null 2>&1; then
  echo 'Every package the scan reads is already available offline; nothing to download.'
  exit 0
fi
if ! bash "$retry" go mod download; then
  echo "::error::Could not download the module's dependencies after ${RETRY_MAX_ATTEMPTS:-3} attempts (see the errors above). The scan did not run; this is not a vulnerability finding."
  exit 1
fi
echo 'Downloaded the module dependencies the scan reads.'
