#!/usr/bin/env bash
# workflow-execution-actors.sh — read-only evidence of actors that started portfolio workflows.
#
# Usage:
#   workflow-execution-actors.sh --org <org> --since <YYYY-MM-DD>
#
# Every active workflow is joined to workflow runs created on or after --since. Each observed run
# actor is resolved again through GitHub's live user API, so the numeric ID and actor type are usable
# as policy evidence rather than inferred from a login. A re-running actor is emitted separately
# when it differs from the actor that started the original run.
#
# Output is tab-separated: repo, workflow, event, actor_role, actor_login, actor_type, actor_id,
# evidence. NO-RUNS means the workflow had no run in the bounded window; it never means no actor is
# required. UNKNOWN means a repository, workflow, history page or actor could not be proved.
#
# Exit codes: 0 complete · 2 UNKNOWN or invalid usage. Partial API output is discarded.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

org=""
since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || usage ;;
    --since) since="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
[ -n "$org" ] || usage

unknown=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
actor_cache="$tmp/actors.tsv"
: >"$actor_cache"

unknown_row() {
  printf '%s\t%s\tUNKNOWN\t-\t-\t-\t-\tUNKNOWN\n' "$1" "$2"
  unknown=1
}

# resolve_actor <login> <history-type> <history-id>
# Verifies run-embedded identity data against a fresh live user record. The cache is evidence from
# this invocation only; a renamed/deleted/unreadable actor fails closed instead of preserving a
# stale identity.
resolve_actor() {
  local login="$1" history_type="$2" history_id="$3"
  local cached encoded live live_id live_type
  cached="$(awk -F '\t' -v login="$login" '$1 == login { print $2 "\t" $3; exit }' "$actor_cache")"
  if [ -z "$cached" ]; then
    encoded="$(jq -nr --arg value "$login" '$value | @uri')" || return 1
    live="$(gh api "users/$encoded" --jq '[.id, .type] | @tsv' 2>/dev/null)" || return 1
    IFS=$'\t' read -r live_id live_type <<<"$live"
    [[ "$live_id" =~ ^[0-9]+$ ]] || return 1
    case "$live_type" in User | Bot) ;; *) return 1 ;; esac
    printf '%s\t%s\t%s\n' "$login" "$live_id" "$live_type" >>"$actor_cache"
  else
    IFS=$'\t' read -r live_id live_type <<<"$cached"
  fi
  [ "$history_id" = "$live_id" ] && [ "$history_type" = "$live_type" ]
}

printf 'repo\tworkflow\tevent\tactor_role\tactor_login\tactor_type\tactor_id\tevidence\n'

listed="$(gh api "orgs/$org/repos" --paginate --jq '.[] | "\(.archived)\t\(.name)"' 2>/dev/null)" || {
  echo "workflow-execution-actors: UNKNOWN — cannot list $org repositories" >&2
  exit 2
}
expected="$(gh api "orgs/$org" --jq 'if .total_private_repos == null then "" else .public_repos + .total_private_repos end' 2>/dev/null)" || expected=""
listed_count="$(grep -c . <<<"$listed")"
if [ -z "$expected" ] || [ "$listed_count" != "$expected" ]; then
  echo "workflow-execution-actors: UNKNOWN — listed $listed_count of ${expected:-an unknown number of} $org repositories; the token cannot see them all" >&2
  exit 2
fi

repos="$(sed -n $'s/^false\t//p' <<<"$listed")"
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  workflows="$tmp/workflows"
  if ! gh api "repos/$org/$repo/actions/workflows?per_page=100" --paginate \
    --jq '.workflows[] | select(.state == "active") | [.id, .path] | @tsv' >"$workflows" 2>"$tmp/error"; then
    unknown_row "$repo" UNKNOWN
    continue
  fi
  sort -u "$workflows" -o "$workflows"

  while IFS=$'\t' read -r workflow_id workflow_path; do
    [ -n "$workflow_id" ] && [ -n "$workflow_path" ] || continue
    case "$workflow_path" in .github/workflows/*) ;; *) continue ;; esac
    runs="$tmp/runs"
    # shellcheck disable=SC2016 # $run is a jq variable inside the single-quoted filter.
    if ! gh api "repos/$org/$repo/actions/workflows/$workflow_id/runs?per_page=100&created=%3E%3D$since" \
      --paginate --jq '
        .workflow_runs[] as $run |
        ({role:"actor", value:$run.actor},
         {role:"triggering_actor", value:(
           if (($run.triggering_actor.id // null) != ($run.actor.id // null))
           then $run.triggering_actor else null end)}) |
        select(.value != null) |
        [$run.event, .role, .value.login, .value.type, (.value.id | tostring)] | @tsv
      ' >"$runs" 2>"$tmp/error"; then
      unknown_row "$repo" "$workflow_path"
      continue
    fi
    sort -u "$runs" -o "$runs"
    if [ ! -s "$runs" ]; then
      printf '%s\t%s\tNO-RUNS\t-\t-\t-\t-\tNO-RUNS\n' "$repo" "$workflow_path"
      continue
    fi

    verified="$tmp/verified"
    : >"$verified"
    workflow_verified=1
    while IFS=$'\t' read -r event actor_role actor_login actor_type actor_id; do
      if [ -z "$event" ] || [ -z "$actor_role" ] || [ -z "$actor_login" ] ||
        [ -z "$actor_type" ] || ! [[ "$actor_id" =~ ^[0-9]+$ ]] ||
        ! resolve_actor "$actor_login" "$actor_type" "$actor_id"; then
        workflow_verified=0
        break
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tOBSERVED\n' \
        "$repo" "$workflow_path" "$event" "$actor_role" "$actor_login" "$actor_type" "$actor_id" >>"$verified"
    done <"$runs"
    if [ "$workflow_verified" -eq 1 ]; then
      cat "$verified"
    else
      unknown_row "$repo" "$workflow_path"
    fi
  done <"$workflows"
done <<<"$repos"

if [ "$unknown" -ne 0 ]; then
  echo "workflow-execution-actors: UNKNOWN — some evidence could not be read or verified" >&2
  exit 2
fi
