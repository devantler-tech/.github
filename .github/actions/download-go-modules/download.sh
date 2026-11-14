#!/usr/bin/env bash
# Download the modules the job needs before it builds, tests or lints, through the
# shared bounded retry, so a transient module-proxy or network error is retried
# instead of failing the job. Only the download is retried. With every module
# already in the restored cache, Go makes no network request. A checksum mismatch
# or a missing version fails every attempt and still fails the job.
set -euo pipefail
module="$1" retry="$2"
cd "$module"
if ! bash "$retry" go mod download; then
  echo "::error::Could not download the Go modules after ${RETRY_MAX_ATTEMPTS:-3} attempts (see the errors above). No build, test or lint step ran." >&2
  exit 1
fi
echo 'Every Go module the job needs is available.'
