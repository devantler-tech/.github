#!/usr/bin/env bash
#
# Reports every declared repository setting in deploy/ that disagrees with the
# live repository on GitHub.
#
# A Repository managed resource only issues an update PATCH when it has a
# pending diff, so one whose writes are rejected still reports
# Synced=ReconcileSuccess once the provider stops retrying. A declaration that
# never landed is therefore indistinguishable from one that did, by reading
# cluster state alone. This compares the two ends directly instead.
#
# Read-only. It never writes GitHub state, so it is safe to run against the
# managed org (deploy/ stays the only way to change configuration).
#
# Environment:
#   REPOSITORY_DRIFT_OWNER      org to read live state from (default devantler-tech)
#   REPOSITORY_DRIFT_RENDER     pre-rendered deploy/ manifest; default renders deploy/
#   REPOSITORY_DRIFT_LIVE_DIR   directory of <repo>.json live fixtures; default reads
#                               the GitHub API. Used by tests to stay hermetic.
#
# Exit codes:
#   0  every declared field matches live
#   1  at least one declared field diverges from live
#   2  the check could not be completed (fail closed)

set -euo pipefail

owner="${REPOSITORY_DRIFT_OWNER:-devantler-tech}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="${REPOSITORY_DRIFT_RENDER:-}"
live_dir="${REPOSITORY_DRIFT_LIVE_DIR:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

abort() {
  echo "repository-drift: $*" >&2
  exit 2
}

for tool in yq jq; do
  command -v "$tool" >/dev/null || abort "required tool '$tool' not found"
done

if [[ -z "$live_dir" ]]; then
  command -v gh >/dev/null || abort "required tool 'gh' not found"
fi

if [[ -z "$render" ]]; then
  command -v kubectl >/dev/null || abort "required tool 'kubectl' not found"
  render="$work/render.yaml"
  kubectl kustomize "$repo_root/deploy" >"$render" ||
    abort "kubectl kustomize deploy/ failed"
fi
[[ -s "$render" ]] || abort "rendered manifest is empty"

# One JSON object per declared Repository: the repository it points at, the
# resource that declares it, and the settings block deploy/ claims authority
# over.
#
# crossplane.io/external-name is what identifies the repository on GitHub, and
# it is not always the resource name — an adoption after a rename carries the
# new name there while the resource keeps its own. Reading live state by the
# resource name would then compare against the wrong repository, or against
# none at all.
yq -N -o=json -I=0 '
  select(.kind == "Repository") |
  {
    "repo": (.metadata.annotations["crossplane.io/external-name"] // .metadata.name),
    "resource": .metadata.name,
    "declared": .spec.forProvider
  }
' "$render" >"$work/declared.jsonl" || abort "failed to read Repository resources from the render"

declared_count="$(grep -c . "$work/declared.jsonl" || true)"
# deploy/ manages the whole org; a render that yields almost nothing means the
# read broke rather than that the org shrank, and reporting "no drift" from it
# would be a fail-open.
[[ "$declared_count" -ge 10 ]] ||
  abort "declared Repository set collapsed to $declared_count entries"

# forProvider is camelCase; the REST repository object is snake_case. Only
# homepageUrl is not a pure case change.
readonly KEY_PROGRAM='
  def to_snake: gsub("(?<c>[A-Z])"; "_" + (.c | ascii_downcase));
  def api_key: {"homepageUrl": "homepage"}[.] // to_snake;
'

drift_found=0

while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  repo="$(jq -r '.repo' <<<"$entry")"
  # Only worth saying when the two differ; otherwise it is noise on every line.
  where="$(jq -r 'if .resource == .repo then "" else " [declared by \(.resource)]" end' <<<"$entry")"
  is_private=false

  if [[ -n "$live_dir" ]]; then
    live_file="$live_dir/$repo.json"
    [[ -f "$live_file" ]] || abort "no live fixture for '$repo' at $live_file"
    live="$(cat "$live_file")"
  else
    live="$(gh api "repos/$owner/$repo")" ||
      abort "failed to read live state for '$owner/$repo'"
  fi
  jq -e 'type == "object"' >/dev/null <<<"$live" ||
    abort "live state for '$repo' is not a JSON object"

  # This repository is public, so its Actions logs are public. A private
  # repository's description, homepage or topics must not be printed into them,
  # so a finding on one names the field and withholds both values. Absent the
  # flag the sensitivity cannot be judged, so it aborts rather than guessing.
  jq -e 'has("private")' >/dev/null <<<"$live" ||
    abort "live state for '$repo' has no 'private' flag, so its findings cannot be safely printed"
  is_private="$(jq -r 'if .private == true then "true" else "false" end' <<<"$live")"

  # A declared field with no counterpart on the live object means the mapping
  # is wrong or the API changed shape. Silently skipping it would let a whole
  # class of settings go unchecked while the run still reported success, so it
  # aborts instead of passing.
  findings="$(
    jq -c --argjson live "$live" "$KEY_PROGRAM"'
      .declared
      | to_entries
      | map(
          (.key | api_key) as $k
          | if ($live | has($k)) | not then
              {field: .key, api: $k, status: "unmapped"}
            else
              (if $k == "topics" then (.value | unique) else .value end) as $want
              | (if $k == "topics" then ($live[$k] | unique) else $live[$k] end) as $got
              | if $want == $got then empty
                else {field: .key, api: $k, declared: $want, live: $got, status: "drift"}
                end
            end
        )
      | .[]
    ' <<<"$entry"
  )" || abort "failed to compare declared and live state for '$repo'"

  while IFS= read -r finding; do
    [[ -n "$finding" ]] || continue
    if [[ "$(jq -r '.status' <<<"$finding")" == "unmapped" ]]; then
      abort "$(jq -r --arg repo "$repo" --arg where "$where" '
        "\($repo)\($where) declares \(.field) but the live repository object has no \(.api|tojson) field"
      ' <<<"$finding")"
    fi
    drift_found=1
    jq -r --arg repo "$repo" --arg where "$where" --argjson private "$is_private" '
      "DRIFT \($repo).\(.field)\($where): " +
      (if $private then "values withheld — private repository"
       else "declared=\(.declared | tojson) live=\(.live | tojson)" end)
    ' <<<"$finding"
  done <<<"$findings"
done <"$work/declared.jsonl"

if [[ "$drift_found" -ne 0 ]]; then
  echo "repository-drift: declared and live GitHub state disagree (see DRIFT lines above)" >&2
  exit 1
fi

echo "repository-drift: OK — $declared_count declared repositories match live GitHub state"
