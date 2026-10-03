#!/usr/bin/env bash
# Refresh the reviewed version-to-digest rows in .scripts/gh-release-digests.tsv.
#
# Usage:  bash .scripts/refresh-gh-digests.sh <version>        # e.g. 2.90.0
#
# Fetches the checksums file cli/cli publishes for that release, extracts the digests for
# the four assets ensure-gh-skill.sh can install, and rewrites those rows in place. The
# point is that the value entering the repository is the one the release actually
# published, transcribed mechanically rather than by hand, and then reviewed in a pull
# request before anything trusts it.
#
# Run this from CI or locally when bumping the version ensure-gh-skill.sh requires, and
# review the resulting diff like any other change. Rows for other versions are preserved,
# so a consumer pinning an older gh keeps its guarantee.
set -euo pipefail

version="${1:-}"
if [ -z "$version" ]; then
  echo "usage: $0 <version>   (e.g. $0 2.90.0)" >&2
  exit 2
fi
# Reject anything that is not a plain dotted version before it reaches a URL: this argument
# is the only untrusted input here, and it must never be able to redirect the fetch.
# Bash-native match, not `printf | grep -q`: with `set -o pipefail` an early grep exit can
# SIGPIPE the printf and invert the result.
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::version must be a bare X.Y.Z (got '$version')" >&2
  exit 2
fi

manifest="$(dirname "${BASH_SOURCE[0]}")/gh-release-digests.tsv"
if [ ! -f "$manifest" ]; then
  echo "::error::$manifest not found" >&2
  exit 1
fi

sums_url="https://github.com/cli/cli/releases/download/v${version}/gh_${version}_checksums.txt"
tmp=$(mktemp -d "$(dirname "$manifest")/.gh-digests.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# Snapshot the existing reviewed bytes before fetching or preparing replacement.
# Read failures are errors, never an empty set of retained version pins.
cat "$manifest" > "$tmp/original"

echo "Fetching $sums_url"
if ! curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 10 --max-time 60 --max-filesize 1048576 --output "$tmp/sums" "$sums_url"; then
  echo "::error::could not fetch the checksums file for v${version}; is that a published cli/cli release?" >&2
  exit 1
fi

# The exact asset set ensure-gh-skill.sh knows how to install. Keeping this list in step
# with that script's os/arch cases is what stops the manifest from silently pinning fewer
# platforms than the installer actually serves.
rows=""
for pair in "linux amd64 tar.gz" "linux arm64 tar.gz" "macOS amd64 zip" "macOS arm64 zip"; do
  # shellcheck disable=SC2086
  set -- $pair
  os=$1 arch=$2 ext=$3
  asset="gh_${version}_${os}_${arch}.${ext}"
  # Even identical duplicates are ambiguous release input. Check the entire file before
  # trusting a match, and reject trailing fields instead of silently ignoring them.
  if ! digest=$(awk -v want="$asset" '
    $2 == want { count++; digest = $1; if (NF != 2) malformed = 1 }
    END { if (count != 1 || malformed) exit 1; print digest }
  ' "$tmp/sums"); then
    echo "::error::$asset must have exactly one two-field checksum entry; refusing to change the manifest." >&2
    exit 1
  fi
  if ! [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::checksums file gave a malformed digest for $asset: '$digest'" >&2
    exit 1
  fi
  rows="${rows}${version}\t${os}\t${arch}\t${digest}\n"
done

# Drop any existing rows for this version, keep everything else (comments, other
# versions), then append the freshly fetched set and sort the data rows for a stable diff.
awk '/^[[:space:]]*(#|$)/' "$tmp/original" > "$tmp/header"
awk -F'\t' -v v="$version" '!/^[[:space:]]*(#|$)/ && $1 != v' "$tmp/original" > "$tmp/retained"
{
  cat "$tmp/retained"
  printf '%b' "$rows"
} | sort -t"$(printf '\t')" -k1,1V -k2,2 -k3,3 > "$tmp/data"

cat "$tmp/header" "$tmp/data" > "$tmp/manifest"
mv "$tmp/manifest" "$manifest"

echo "Pinned $(printf '%b' "$rows" | grep -c . ) asset digest(s) for v${version} in $manifest"
