#!/usr/bin/env bash
# Download the scanned module's dependencies before the scan, through the shared
# bounded retry, so a transient module-proxy or network error is retried instead
# of failing as if the scan had. Only this download is retried: the scan that
# follows still runs once, so a finding is never retried. Paths are relative to
# the checkout, except the absolute retry helper.
set -euo pipefail
module="$1" retry="$2"
cd "$module"
if [[ -f vendor/modules.txt ]]; then
  echo 'The module vendors its dependencies; the scan reads vendor/ and needs no download.'
  exit 0
fi
if ! bash "$retry" go mod download; then
  echo "::error::Could not download the module's dependencies after ${RETRY_MAX_ATTEMPTS:-3} attempts. This is a module-proxy or network failure, not a vulnerability finding: the scan did not run."
  exit 1
fi
echo 'Downloaded the module dependencies the scan reads.'
