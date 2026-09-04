#!/usr/bin/env bash


set -euo pipefail

# Usage: validate-deploy-deletions.sh <base-render> <head-render> <pr-body-file>
#
# Refuses a pull request whose rendered deploy/ output LOSES a managed resource
# unless the pull-request body acknowledges that exact resource.
#
# Why identity, not file path: the github-config tenant reconciles the RENDERED
# output of `kubectl kustomize deploy/` with prune enabled, so a resource stops
# existing on the live org whenever its identity leaves the render — whether its
# file was deleted, one document was cut out of a multi-document file, or a
# rename changed metadata.name. A path-based diff sees only the first of those.
#
# The identity is `<Kind>.<group>/<name>` (`<Kind>.<group>/<namespace>/<name>`
# for a namespaced document; core-group kinds carry no `.<group>`) — kubectl's
# spelling, and the same key Flux's prune inventory uses. The API GROUP is part
# of it because moving a resource between groups prunes the old managed
# resource, and with the default deletionPolicy that deletes the live GitHub
# object, while a kind/name comparison reads "unchanged". The VERSION is
# deliberately not part of it, so a v1alpha1 → v1beta1 bump is never reported as
# a deletion. A resource that merely changes, or moves between files under the
# same identity, is not a deletion.
#
# Acknowledgement is one line per removed identity in the pull-request body:
#
#   Deletion-Acknowledged: Repository.repo.github.m.upbound.io/doggy-countdown
#
# so a single blanket line cannot cover a deletion nobody meant. A line that
# names a resource the diff does not remove also fails: the body is the audit
# record of what was deliberately deleted, and a stale or pre-emptive line would
# make that record wrong. Matching is exact and whole-line: leading whitespace, a
# list or quote marker (`-`, `*`, `>`), backticks around the identity and a
# trailing CR are tolerated, and HTML comments are stripped first so an
# acknowledgement the reviewer cannot see in the rendered body does not count.
# The body is data and is never evaluated.
#
# Exit codes: 0 OK · 1 an unacknowledged deletion or a stale acknowledgement ·
# 2 the check could not judge (missing tool or file, an empty render, a document
# without kind/name) — never a pass, because an empty base render would
# otherwise read as "nothing to delete".

base_render="${1:-}"
head_render="${2:-}"
body_file="${3:-}"

die_unknown() {
  echo "deploy-deletions: UNKNOWN — $*" >&2
  exit 2
}

[[ -n "$base_render" && -n "$head_render" && -n "$body_file" ]] ||
  die_unknown "usage: validate-deploy-deletions.sh <base-render> <head-render> <pr-body-file>"
for f in "$base_render" "$head_render" "$body_file"; do
  [[ -f "$f" ]] || die_unknown "'$f' is not a readable file"
done
command -v yq >/dev/null 2>&1 || die_unknown "yq is required"

# identities <render-file> — one `<Kind>[.<group>]/[<namespace>/]<name>` per
# document, sorted, unique. Refuses a document that has no kind or no name: such
# a document cannot be reconciled by identity, so the comparison would silently
# ignore it.
identities() {
  local render="$1" ids
  # `yq -N` suppresses the --- separators; `select(. != null)` skips the empty
  # documents a trailing separator produces. `// ""` keeps a missing field visible
  # as an empty segment instead of the literal string "null". The group is the
  # part of apiVersion before its "/"; a core-group apiVersion (`v1`) has no "/"
  # and yields "". Columns are separated by "|", which no group, kind, namespace
  # or name may contain — and unlike a tab it is not IFS whitespace, so an EMPTY
  # column (a cluster-scoped document has no namespace) is not collapsed by read.
  ids="$(yq -N 'select(. != null) | [((.apiVersion // "") | sub("^[^/]*$"; "") | sub("/.*$"; "")), (.kind // ""), (.metadata.namespace // ""), (.metadata.name // "")] | join("|")' "$render")" ||
    die_unknown "yq could not read '$render'"
  [[ -n "$ids" ]] || die_unknown "'$render' renders no documents"
  local line group kind ns name id
  while IFS= read -r line; do
    IFS="|" read -r group kind ns name <<<"$line"
    [[ -n "$kind" && -n "$name" ]] ||
      die_unknown "a document in '$render' has no kind or no metadata.name ('$line')"
    id="$kind"
    [[ -z "$group" ]] || id="$kind.$group"
    [[ -z "$ns" ]] || id="$id/$ns"
    printf '%s/%s\n' "$id" "$name"
  done <<<"$ids" | sort -u
}

base_ids="$(identities "$base_render")"
head_ids="$(identities "$head_render")"

# Removed = present at base, absent at head. `comm` needs both inputs sorted,
# which identities() guarantees.
removed="$(comm -23 <(printf '%s\n' "$base_ids") <(printf '%s\n' "$head_ids"))"

# Acknowledged identities, read as whole lines from the body. HTML comments are
# removed first (across lines) so a line hidden from the rendered body cannot
# acknowledge anything; `tr -d '\r'` tolerates a CRLF body; `sed` strips the
# prefix, an optional list/quote marker, optional backticks and surrounding
# whitespace, and accepts an unterminated final line.
strip_html_comments() {
  awk '
    {
      line = $0
      out = ""
      while (line != "") {
        if (in_comment) {
          end = index(line, "-->")
          if (end == 0) { line = ""; break }
          line = substr(line, end + 3)
          in_comment = 0
        } else {
          start = index(line, "<!--")
          if (start == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, start - 1)
          line = substr(line, start + 4)
          in_comment = 1
        }
      }
      print out
    }'
}
# shellcheck disable=SC2016 # the backticks are literal characters to match, not a command substitution
acked="$(tr -d '\r' <"$body_file" | strip_html_comments |
  sed -n -E 's/^[[:space:]]*([-*>][[:space:]]*)?Deletion-Acknowledged:[[:space:]]*`?([^[:space:]`]+)`?[[:space:]]*$/\2/p' |
  sort -u)"

status=0
if [[ -n "$removed" ]]; then
  missing="$(comm -23 <(printf '%s\n' "$removed") <(printf '%s\n' "$acked"))"
  if [[ -n "$missing" ]]; then
    status=1
    echo "deploy-deletions: this pull request REMOVES managed resource(s) from the deploy/ render without acknowledging them; the github-config tenant prunes each one from the live organization on merge." >&2
    echo "deploy-deletions: add one line per resource to the pull-request body (plain text, outside any HTML comment), exactly:" >&2
    while IFS= read -r id; do
      echo "  Deletion-Acknowledged: $id" >&2
    done <<<"$missing"
  fi
fi

stale=""
if [[ -n "$acked" ]]; then
  stale="$(comm -23 <(printf '%s\n' "$acked") <(printf '%s\n' "${removed:-}"))"
fi
if [[ -n "$stale" ]]; then
  status=1
  echo "deploy-deletions: the pull-request body acknowledges deletion(s) the diff does not remove; drop the line(s) so the body stays an accurate record:" >&2
  while IFS= read -r id; do
    echo "  Deletion-Acknowledged: $id" >&2
  done <<<"$stale"
fi

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

if [[ -n "$removed" ]]; then
  count="$(printf '%s\n' "$removed" | wc -l | tr -d ' ')"
  echo "deploy-deletions: OK — $count removed resource(s), each acknowledged in the pull-request body:"
  while IFS= read -r id; do
    echo "  $id"
  done <<<"$removed"
else
  echo "deploy-deletions: OK — no managed resource leaves the deploy/ render"
fi
