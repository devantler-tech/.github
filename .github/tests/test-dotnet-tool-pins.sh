#!/usr/bin/env bash

# Pins how the reusable workflows and composite actions install .NET tools (#265).
#
#   1. Every `dotnet tool install` names an explicit `--version`. An unpinned install takes
#      whatever upstream released last, and publish-dotnet-library.yaml runs dotnet-releaser
#      with the NuGet API key and a write-capable token.
#   2. Every tool in the Dependabot-tracked manifest (.github/tools/dotnet/.config/
#      dotnet-tools.json) is installed at exactly the manifest's version. The workflows run in
#      the caller's checkout and cannot read the manifest, so the inline pin is what runs;
#      this check is what makes a Dependabot bump of the manifest reach it.
#   3. dotnet-releaser itself stays in the manifest, so its bumps keep being proposed.

set -euo pipefail

manifest=".github/tools/dotnet/.config/dotnet-tools.json"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$manifest" ]] || fail "missing tool manifest: $manifest"

releaser="$(jq -r '.tools["dotnet-releaser"].version // ""' "$manifest")"
[[ -n "$releaser" ]] || fail "$manifest must track dotnet-releaser so Dependabot proposes its bumps"

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
  tool="$(printf '%s\n' "$command" | sed -nE 's/.*dotnet tool install[[:space:]]+(--global[[:space:]]+|-g[[:space:]]+)?([^[:space:]-][^[:space:]]*).*/\2/p')"
  tracked="$(jq -r --arg t "$tool" '.tools[$t].version // ""' "$manifest")"
  if [[ -n "$tracked" && "$tracked" != "$version" ]]; then
    fail "$where installs $tool $version, but $manifest tracks $tracked — update the inline pin to $tracked"
  fi
done <<<"$installs"

grep -rqE "dotnet tool install.*dotnet-releaser.*--version[[:space:]=]+$releaser" .github/workflows ||
  fail "no workflow installs dotnet-releaser at the tracked version $releaser"

echo "ok   every .NET tool install is pinned, and tracked tools match $manifest"
