#!/usr/bin/env bash
# Download the scanned module's dependencies before the scan, through the shared
# bounded retry, so a transient module-proxy or network error is retried instead
# of failing as if the scan had. Only this download is retried: the scan that
# follows still runs once, so a finding is never retried. Paths are relative to
# the checkout, except the absolute retry helper.
set -euo pipefail
module="$1" retry="$2"
cd "$module"
# A vendored build reads vendor/ and needs no download. In workspace mode Go uses
# only the workspace's vendor directory, beside go.work, and ignores a module's own.
workspace="$(go env GOWORK)"
vendor_dir=vendor
if [[ -n "$workspace" && "$workspace" != off ]]; then
  vendor_dir="$(dirname "$workspace")/vendor"
fi
if [[ -f "$vendor_dir/modules.txt" ]]; then
  echo "The build reads vendored dependencies from $vendor_dir and needs no download."
  exit 0
fi
if ! bash "$retry" go mod download; then
  echo "::error::Could not download the module's dependencies after ${RETRY_MAX_ATTEMPTS:-3} attempts. This is a module-proxy or network failure, not a vulnerability finding: the scan did not run."
  exit 1
fi
echo 'Downloaded the module dependencies the scan reads.'
