#!/usr/bin/env bash
# Fetch what the scan reads before the scan, through the shared bounded retry, so
# a transient module-proxy or network error is retried instead of failing as if
# the scan had. Only this load is retried: the scan that follows still runs once,
# so a finding is never retried. Paths are relative to the checkout, except the
# absolute retry helper.
set -euo pipefail
module="$1" retry="$2"
cd "$module"
# Load exactly the packages the scan loads (./..., without tests). Go then fetches
# only the modules the scan reads, and itself decides vendoring, workspaces, -mod
# flags and the cache; with nothing missing it makes no network request.
if ! bash "$retry" go list -deps ./... >/dev/null; then
  echo "::error::Could not load the scanned packages after ${RETRY_MAX_ATTEMPTS:-3} attempts (see the errors above). The scan did not run; this is not a vulnerability finding."
  exit 1
fi
echo 'Every package the scan reads is available.'
