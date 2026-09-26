#!/usr/bin/env bash

# Pins how the reusable workflows and composite actions install .NET tools (#265).
#
#   1. Every `dotnet tool install` names an exact `--version`. An unpinned install takes
#      whatever upstream released last, and publish-dotnet-library.yaml runs dotnet-releaser
#      with the NuGet API key and a write-capable token.
#   2. dotnet-releaser in particular stays pinned, so removing its install line cannot make
#      this check pass vacuously.
#
# The pins are bumped by hand after reviewing the upstream release. A Dependabot-tracked tool
# manifest is deliberately not used: adding one turns on GitHub's automatic NuGet dependency
# submission, which restores the deliberately broken .github/fixtures projects and fails.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

installs="$(grep -rnE 'dotnet tool install' .github/workflows actions --include='*.yaml' --include='*.yml' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
[[ -n "$installs" ]] || fail "found no 'dotnet tool install' lines — refusing to pass vacuously"

while IFS= read -r line; do
  where="${line%%:*}:$(printf '%s' "$line" | cut -d: -f2)"
  command="${line#*:*:}"
  version="$(printf '%s\n' "$command" | sed -nE 's/.*--version[[:space:]=]+([^[:space:]]+).*/\1/p')"
  [[ -n "$version" ]] || fail "$where installs a .NET tool without --version: ${command#"${command%%[![:space:]]*}"}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "$where pins '$version', which is not an exact version"
done <<<"$installs"

grep -rqE 'dotnet tool install.*dotnet-releaser.*--version[[:space:]=]+[0-9]+\.[0-9]+\.[0-9]+' .github/workflows ||
  fail "no workflow installs dotnet-releaser at an exact --version"

echo "ok   every .NET tool install is pinned to an exact version"
