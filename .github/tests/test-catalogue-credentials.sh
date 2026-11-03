#!/usr/bin/env bash
# Audit every catalogue CI job and reached reusable/composite source without running it.
set -euo pipefail
root="$(pwd)"
module="$root/tests/catalogue-credentials"
(cd "$module" && go run . "$root")
