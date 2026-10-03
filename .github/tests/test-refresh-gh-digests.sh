#!/usr/bin/env bash
# Exercise the real manifest refresh with a closed, offline release-checksum fixture.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/work"
cp "$root/.scripts/refresh-gh-digests.sh" "$tmp/work/refresh-gh-digests.sh"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 4 ] || [ "$1" != -fsSL ] || [ "$2" != -o ] ||
   [ "$4" != https://github.com/cli/cli/releases/download/v999.0.0/gh_999.0.0_checksums.txt ]; then
  echo 'unexpected checksum download request' >&2
  exit 90
fi
printf 'called\n' >> "$CURL_CALLS"
cp "$CURL_FIXTURE" "$3"
if [ "${CURL_FAIL:-false}" = true ]; then exit 22; fi
STUB
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" CURL_FIXTURE="$tmp/sums" CURL_CALLS="$tmp/calls"
manifest="$tmp/work/gh-release-digests.tsv"
make_fixture() {
  : > "$tmp/sums"
  for pair in 'linux amd64 tar.gz a' 'linux arm64 tar.gz b' 'macOS amd64 zip c' 'macOS arm64 zip d'; do
    # shellcheck disable=SC2086
    set -- $pair
    digest=$(printf '%64s' '' | tr ' ' "$4")
    printf '%s  gh_999.0.0_%s_%s.%s\n' "$digest" "$1" "$2" "$3" >> "$tmp/sums"
  done
  printf '# reviewed manifest\n\n2.90.0\tlinux\tamd64\t%s\n999.0.0\tlinux\tamd64\t%s\n' \
    "$(printf '%64s' '' | tr ' ' e)" "$(printf '%64s' '' | tr ' ' 0)" > "$manifest"
  cp "$manifest" "$tmp/before"
  : > "$tmp/calls"
}
reject() {
  local name=$1
  if bash "$tmp/work/refresh-gh-digests.sh" 999.0.0 > "$tmp/log" 2>&1; then
    echo "FAIL: $name accepted invalid checksum input" >&2
    exit 1
  fi
  if ! cmp -s "$manifest" "$tmp/before"; then
    echo "FAIL: $name changed the reviewed manifest" >&2
    exit 1
  fi
  echo "PASS: $name rejects input and preserves manifest bytes"
}

make_fixture
printf '%s  gh_999.0.0_macOS_arm64.zip\n' "$(printf '%64s' '' | tr ' ' f)" >> "$tmp/sums"
reject conflicting-duplicate
make_fixture
tail -n 1 "$tmp/sums" >> "$tmp/duplicate"
cat "$tmp/duplicate" >> "$tmp/sums"
reject identical-duplicate
make_fixture
sed '$d' "$tmp/sums" > "$tmp/missing"
mv "$tmp/missing" "$tmp/sums"
reject missing-final-platform
make_fixture
sed 's/^d/INVALID/' "$tmp/sums" > "$tmp/malformed"
mv "$tmp/malformed" "$tmp/sums"
reject malformed-digest
make_fixture
sed '$s/$/ unexpected-token/' "$tmp/sums" > "$tmp/malformed"
mv "$tmp/malformed" "$tmp/sums"
reject extra-checksum-fields
make_fixture
export CURL_FAIL=true
reject failed-download-with-partial-payload
unset CURL_FAIL

make_fixture
for version in '' 999.0 999.0.0-extra '999.0.0?redirect=1'; do
  if bash "$tmp/work/refresh-gh-digests.sh" "$version" > "$tmp/log" 2>&1; then
    echo 'FAIL: malformed version accepted' >&2; exit 1
  fi
  cmp -s "$manifest" "$tmp/before"
  [ ! -s "$tmp/calls" ]
done
echo 'PASS: invalid versions fail before download or manifest writes'

make_fixture
bash "$tmp/work/refresh-gh-digests.sh" 999.0.0 > "$tmp/log" 2>&1
printf '%s\n' \
  '999.0.0 linux amd64 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '999.0.0 linux arm64 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  '999.0.0 macOS amd64 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  '999.0.0 macOS arm64 dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
  | tr ' ' '\t' > "$tmp/expected"
awk -F '\t' '$1 == "999.0.0"' "$manifest" > "$tmp/current"
if ! cmp -s "$tmp/expected" "$tmp/current"; then
  echo 'FAIL: manifest does not bind every platform to its exact release digest' >&2
  exit 1
fi
grep -Fx '# reviewed manifest' "$manifest" > /dev/null
grep '^2.90.0' "$manifest" > "$tmp/old-after"
grep '^2.90.0' "$tmp/before" > "$tmp/old-before"
cmp -s "$tmp/old-after" "$tmp/old-before"
cp "$manifest" "$tmp/once"
bash "$tmp/work/refresh-gh-digests.sh" 999.0.0 > "$tmp/log" 2>&1
cmp -s "$manifest" "$tmp/once"
[ "$(wc -l < "$tmp/calls" | tr -d ' ')" -eq 2 ]
echo 'PASS: unique platform digests replace exactly four rows, preserve older pins and are idempotent'
