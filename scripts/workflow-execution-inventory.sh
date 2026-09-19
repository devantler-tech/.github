#!/usr/bin/env bash
# workflow-execution-inventory.sh — read-only inventory of who and what can start each workflow.
#
# Lists every GitHub Actions workflow with the events that can start it, an exposure class, and the
# number of workflow execution policies set on its repository. It is the evidence a layered
# workflow execution policy is designed from: which workflows accept manual or cross-repository
# entry, which run with a privileged trigger, and which publish or deploy.
#
# Usage:
#   workflow-execution-inventory.sh --org <org>                    # every active repository, live
#   workflow-execution-inventory.sh --dir <workflows-dir> [--repo <name>]   # local files only
#
# Output is tab-separated: repo, workflow, events, exposure, repo_policies.
# Exposure classes (comma-separated when several apply):
#   privileged-trigger   pull_request_target or workflow_run: runs with base-repository privileges
#   manual-entry         workflow_dispatch or repository_dispatch
#   release              the workflow's file or display name says it publishes, releases or deploys
#   reusable             workflow_call
#   scheduled            schedule
#   ci                   none of the above
# The release class is a naming heuristic; confirm each hit by reading the workflow.
#
# Exit codes: 0 complete · 2 UNKNOWN — at least one repository, listing or workflow could not be
# read or parsed. Those rows say UNKNOWN; a partial inventory is never reported as complete.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

unknown=0

# events <file> — one event name per line; nothing on a parse failure.
events() {
  yq -r '.on | ((select(tag == "!!str")), (select(tag == "!!seq") | .[]),
    (select(tag == "!!map") | keys | .[]))' "$1" 2>/dev/null | grep -v '^$' | sort -u || true
}

# classify <file> <workflow-name> — prints "<events>\t<exposure>" or UNKNOWN.
classify() {
  local file="$1" name="$2" evs display classes=()
  evs="$(events "$file")"
  if [ -z "$evs" ]; then
    printf 'UNKNOWN\tUNKNOWN'
    return
  fi
  display="$(yq -r '.name // ""' "$file" 2>/dev/null || true)"
  grep -qxE 'pull_request_target|workflow_run' <<<"$evs" && classes+=(privileged-trigger)
  grep -qxE 'workflow_dispatch|repository_dispatch' <<<"$evs" && classes+=(manual-entry)
  grep -qiE '(^|[^a-z])(cd|deploy|publish|release)' <<<"$name $display" && classes+=(release)
  grep -qx 'workflow_call' <<<"$evs" && classes+=(reusable)
  grep -qx 'schedule' <<<"$evs" && classes+=(scheduled)
  [ "${#classes[@]}" -eq 0 ] && classes=(ci)
  local IFS=,
  printf '%s\t%s' "$(tr '\n' ',' <<<"$evs" | sed 's/,$//')" "${classes[*]}"
}

# inventory_dir <repo> <dir> <policies> — one row per workflow file in <dir>.
inventory_dir() {
  local repo="$1" dir="$2" policies="$3" f row
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    # classify runs in a subshell, so its verdict is read from the row, not from a variable.
    row="$(classify "$f" "$(basename "$f")")"
    case "$row" in UNKNOWN*) unknown=1 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$repo" "$(basename "$f")" "$row" "$policies"
  done
}

inventory_org() {
  local org="$1" repos repo policies listing name
  repos="$(gh api "orgs/$org/repos" --paginate --jq '.[] | select(.archived | not) | .name')" ||
    { echo "workflow-execution-inventory: UNKNOWN — cannot list $org repositories" >&2; exit 2; }
  [ -n "$repos" ] || { echo "workflow-execution-inventory: UNKNOWN — $org listed no repositories" >&2; exit 2; }
  # Global, not local: the EXIT trap runs after this function has returned.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  while IFS= read -r repo; do
    policies="$(gh api "repos/$org/$repo/actions/policies" --jq '.total_count' 2>/dev/null)" ||
      { policies=UNKNOWN; unknown=1; }
    if ! listing="$(gh api "repos/$org/$repo/contents/.github/workflows" \
      --jq '.[] | select(.type == "file") | .name' 2>"$tmp/err")"; then
      if grep -q 'HTTP 404' "$tmp/err"; then
        continue  # no workflows directory: nothing can start
      fi
      printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\t%s\n' "$repo" "$policies"
      unknown=1
      continue
    fi
    rm -rf "${tmp:?}/wf" && mkdir "$tmp/wf"
    while IFS= read -r name; do
      case "$name" in *.yml | *.yaml) ;; *) continue ;; esac
      gh api "repos/$org/$repo/contents/.github/workflows/$name" \
        -H 'Accept: application/vnd.github.raw' >"$tmp/wf/$name" 2>/dev/null ||
        { : >"$tmp/wf/$name"; }  # an empty file classifies as UNKNOWN
    done <<<"$listing"
    inventory_dir "$repo" "$tmp/wf" "$policies"
  done <<<"$repos"
}

mode="" target="" repo="local"
while [ $# -gt 0 ]; do
  case "$1" in
    --org) mode=org; target="${2:-}"; shift 2 || usage ;;
    --dir) mode=dir; target="${2:-}"; shift 2 || usage ;;
    --repo) repo="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] && [ -n "$target" ] || usage

printf 'repo\tworkflow\tevents\texposure\trepo_policies\n'
case "$mode" in
  org) inventory_org "$target" ;;
  dir)
    [ -d "$target" ] || { echo "workflow-execution-inventory: no such directory: $target" >&2; exit 2; }
    inventory_dir "$repo" "$target" "n/a"
    ;;
esac

if [ "$unknown" -ne 0 ]; then
  echo "workflow-execution-inventory: UNKNOWN — some rows could not be read or parsed" >&2
  exit 2
fi
