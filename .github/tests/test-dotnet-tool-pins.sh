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

# strip_comment <text>: the text up to an unquoted `#` that starts a word, as the shell reads
# it. A `#` inside single or double quotes is data, so `echo " # x"; dotnet tool install …`
# keeps the install that follows it.
strip_comment() {
  local text=$1 out="" quote="" prev=" " ch i
  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    if [[ -n "$quote" ]]; then
      [[ "$ch" == "$quote" ]] && quote=""
    elif [[ "$ch" == "'" || "$ch" == '"' ]]; then
      quote=$ch
    elif [[ "$ch" == "#" && "$prev" =~ [[:space:]] ]]; then
      break
    fi
    out+=$ch
    prev=$ch
  done
  printf '%s\n' "$out"
}

installs="$(grep -rnE 'dotnet tool install' .github/workflows actions --include='*.yaml' --include='*.yml' |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
[[ -n "$installs" ]] || fail "found no 'dotnet tool install' lines — refusing to pass vacuously"

# One line can chain several commands (`a; b`, `a && b`). Each install command is checked on
# its own, so a pinned install cannot lend its `--version` to an unpinned one on the same line.
releaser_pinned=false
while IFS= read -r line; do
  where="${line%%:*}:$(printf '%s' "$line" | cut -d: -f2)"
  command="${line#*:*:}"
  # Drop a trailing shell comment first, so a `--version` written only in a comment cannot
  # satisfy the check for the install before it.
  command="$(strip_comment "$command")"
  while IFS= read -r segment; do
    [[ "$segment" == *"dotnet tool install"* ]] || continue
    segment="${segment#"${segment%%[![:space:]]*}"}"
    version="$(printf '%s\n' "$segment" | sed -nE 's/.*--version[[:space:]=]+([^[:space:]]+).*/\1/p')"
    [[ -n "$version" ]] || fail "$where installs a .NET tool without --version: $segment"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
      fail "$where pins '$version', which is not an exact version"
    if [[ "$where" == .github/workflows/* && "$segment" =~ (^|[[:space:]])dotnet-releaser([[:space:]]|$) ]]; then
      releaser_pinned=true
    fi
  done < <(printf '%s\n' "$command" | sed -E 's/(;|&&|\|\||\|)/\n/g')
done <<<"$installs"

"$releaser_pinned" || fail "no workflow installs dotnet-releaser at an exact --version"

echo "ok   every .NET tool install is pinned to an exact version"
