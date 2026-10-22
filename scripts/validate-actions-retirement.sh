#!/usr/bin/env bash
# Read-only rendered-state guard for the maintainer-authorized Actions retirement (#240).
# 0: withdrawn; 1: a resource still targets the retired repository; 2: incomplete observation.
set -euo pipefail
# An incomplete render or parser result can never prove that management was withdrawn.
abort() { printf 'actions-retirement: UNKNOWN — %s\n' "$*" >&2; exit 2; }
[[ "$#" == 1 && -f "$1" && ! -L "$1" && -s "$1" ]] ||
  abort 'one non-empty rendered manifest is required'
for tool in yq jq; do command -v "$tool" >/dev/null || abort "missing parser"; done
work="$(mktemp -d)" || abort 'cannot allocate observation directory'
trap 'rm -rf "$work"' EXIT
if ! yq -o=json -I=0 '.' "$1" >"$work/documents.json"; then
  abort 'rendered manifest could not be read completely'
fi
if ! jq -se '
    length > 0 and all(type == "object" and
      (.kind | type == "string" and length > 0) and
      (.metadata.name | type == "string" and length > 0))
  ' "$work/documents.json" >/dev/null; then
  abort 'rendered resource inventory is empty or malformed'
fi
if ! jq -s '
    def retired: if type == "string" then ascii_downcase == "actions" else false end;
    [ .[] | select(
        ((.kind == "Repository") and
          ([.spec.forProvider.name, .spec.initProvider.name,
            .metadata.annotations["crossplane.io/external-name"]] | any(retired))) or
        ([.spec.forProvider.repository, .spec.initProvider.repository] | any(retired))
      ) ] | length
  ' "$work/documents.json" >"$work/count"; then
  abort 'retirement selector failed'
fi
count="$(<"$work/count")"
[[ "$count" =~ ^[0-9]+$ ]] || abort 'invalid retirement observation'
if ((count > 0)); then
  printf 'actions-retirement: retired catalogue is still managed (%s resources)\n' "$count" >&2
  exit 1
fi
printf 'actions-retirement: no managed resources target the retired catalogue\n'
