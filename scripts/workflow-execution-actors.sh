#!/usr/bin/env bash
# workflow-execution-actors.sh — read-only evidence of actors that started portfolio workflows.
#
# Usage:
#   workflow-execution-actors.sh --org <org> --since <YYYY-MM-DD> [--until <YYYY-MM-DD>]
#
# Every active workflow is joined to workflow runs created from --since through --until (default:
# today, UTC). Runs are read over closed ranges that end no later than the moment the script
# starts, so a range cannot grow while its pages are read. GitHub caps a filtered run list at
# 1,000 results, so a workflow whose window reaches the cap is re-read one UTC day at a time. A day
# that still reaches the cap, or a total that changes between pages, is UNKNOWN. Each observed run
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
until=""
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || usage ;;
    --since) since="${2:-}"; shift 2 || usage ;;
    --until) until="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
cutoff="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
until="${until:-${cutoff%%T*}}"
[[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
[[ "$until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
[ -n "$org" ] || usage
# Closed <start>..<end> ranges ending no later than the start-up cutoff: the whole window first,
# then one per UTC day for a workflow whose whole window reaches the cap.
day_windows="$(jq -nr --arg since "$since" --arg until "$until" --arg cutoff "$cutoff" '
  ($since + "T00:00:00Z" | fromdateiso8601) as $from |
  ($until + "T00:00:00Z" | fromdateiso8601) as $to |
  ($cutoff | fromdateiso8601) as $cut |
  if $to < $from or $from > $cut then error("empty window") else empty end,
  (range($from; $to + 86400; 86400) | select(. <= $cut) |
    "\(todate)..\([. + 86399, $cut] | min | todate)")
' 2>/dev/null)" || usage
full_window="$(head -1 <<<"$day_windows")"
full_window="${full_window%%..*}..$(tail -1 <<<"$day_windows" | sed 's/.*\.\.//')"
day_window_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$day_windows")"

unknown=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
actor_cache="$tmp/actors.tsv"
: >"$actor_cache"

unknown_row() {
  printf '%s\t%s\tUNKNOWN\t-\t-\t-\t-\tUNKNOWN\n' "$1" "$2"
  unknown=1
}

# read_window <workflow-id> <created-range> <append-to>
# Appends the runs created in one closed range to <append-to> (repository: $repo). Returns 0 when
# the range was read completely, 3 when it reached GitHub's 1,000-result cap (so a narrower range
# may still succeed), and 1 for any other incomplete read, including a total that changed between
# pages.
read_window() {
  local workflow_id="$1" window="$2" append_to="$3"
  local page="$tmp/page" run_rows="$tmp/run-rows"
  local run_count run_count_value_count actual_run_count
  # shellcheck disable=SC2016 # $run is a jq variable inside the single-quoted filter.
  if ! gh api "repos/$org/$repo/actions/workflows/$workflow_id/runs?per_page=100&created=$window" \
    --paginate --jq '
      (["__META__", (.total_count | tostring), "-", "-", "-", "-", "-"] | @tsv),
      (.workflow_runs[] as $run |
        ({role:"actor", value:($run.actor // {})},
         (if (($run.triggering_actor.id // null) != ($run.actor.id // null))
          then {role:"triggering_actor", value:$run.triggering_actor} else empty end)) |
        [$run.event, .role, .value.login, .value.type, (.value.id | tostring),
         ($run.id | tostring), ($run.run_attempt | tostring)] | @tsv)
    ' >"$page" 2>"$tmp/error"; then
    return 1
  fi
  run_count="$(awk -F '\t' '$1 == "__META__" { print $2 }' "$page" | sort -u)"
  # Past the cap GitHub serves one more page reporting a total of zero, so a capped range shows
  # two totals. Any page at or over the cap marks the whole range capped.
  if awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1000 { capped=1 } END { exit(capped ? 0 : 1) }' \
    <<<"$run_count"; then
    return 3
  fi
  run_count_value_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$run_count")"
  [ "$run_count_value_count" -eq 1 ] && [[ "$run_count" =~ ^[0-9]+$ ]] || return 1
  awk -F '\t' '$1 != "__META__"' "$page" >"$run_rows"
  actual_run_count="$(awk -F '\t' '{ print $6 }' "$run_rows" | sort -u |
    awk 'NF { count++ } END { print count + 0 }')"
  [ "$actual_run_count" -eq "$run_count" ] || return 1
  cat "$run_rows" >>"$append_to"
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
listed_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"$listed")"
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
    : >"$runs"
    windows_complete=1
    window_status=0
    read_window "$workflow_id" "$full_window" "$runs" || window_status=$?
    if [ "$window_status" -eq 3 ] && [ "$day_window_count" -gt 1 ]; then
      : >"$runs"
      while IFS= read -r window; do
        [ -n "$window" ] || continue
        if ! read_window "$workflow_id" "$window" "$runs"; then
          windows_complete=0
          break
        fi
      done <<<"$day_windows"
    elif [ "$window_status" -ne 0 ]; then
      windows_complete=0
    fi
    if [ "$windows_complete" -ne 1 ]; then
      unknown_row "$repo" "$workflow_path"
      continue
    fi

    run_attempts="$tmp/run-attempts"
    awk -F '\t' '{ print $6 "\t" $7 }' "$runs" | sort -u >"$run_attempts"
    history_complete=1
    while IFS=$'\t' read -r run_id run_attempt; do
      [ -n "$run_id" ] && [ -n "$run_attempt" ] || continue
      if ! [[ "$run_id" =~ ^[0-9]+$ ]] || ! [[ "$run_attempt" =~ ^[0-9]+$ ]] ||
        [ "$run_attempt" -lt 1 ]; then
        history_complete=0
        break
      fi
      attempt=1
      while [ "$attempt" -lt "$run_attempt" ]; do
        attempt_rows="$tmp/attempt-$run_id-$attempt"
        # shellcheck disable=SC2016 # $run is a jq variable inside the single-quoted filter.
        if ! gh api "repos/$org/$repo/actions/runs/$run_id/attempts/$attempt" --jq '
          . as $run |
          ({role:"actor", value:($run.actor // {})},
           (if (($run.triggering_actor.id // null) != ($run.actor.id // null))
            then {role:"triggering_actor", value:$run.triggering_actor} else empty end)) |
          [$run.event, .role, .value.login, .value.type, (.value.id | tostring),
           ($run.id | tostring), ($run.run_attempt | tostring)] | @tsv
        ' >"$attempt_rows" 2>"$tmp/error"; then
          history_complete=0
          break 2
        fi
        if ! awk -F '\t' -v id="$run_id" -v attempt="$attempt" \
          'NF != 7 || $6 != id || $7 != attempt { bad=1 } END { exit bad }' "$attempt_rows"; then
          history_complete=0
          break 2
        fi
        cat "$attempt_rows" >>"$runs"
        attempt=$((attempt + 1))
      done
    done <"$run_attempts"
    if [ "$history_complete" -ne 1 ]; then
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
    while IFS=$'\t' read -r event actor_role actor_login actor_type actor_id run_id run_attempt; do
      if [ -z "$event" ] || [ -z "$actor_role" ] || [ -z "$actor_login" ] ||
        [ -z "$actor_type" ] || ! [[ "$actor_id" =~ ^[0-9]+$ ]] ||
        ! [[ "$run_id" =~ ^[0-9]+$ ]] || ! [[ "$run_attempt" =~ ^[0-9]+$ ]] ||
        ! resolve_actor "$actor_login" "$actor_type" "$actor_id"; then
        workflow_verified=0
        break
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tOBSERVED\n' \
        "$repo" "$workflow_path" "$event" "$actor_role" "$actor_login" "$actor_type" "$actor_id" >>"$verified"
    done <"$runs"
    if [ "$workflow_verified" -eq 1 ]; then
      sort -u "$verified"
    else
      unknown_row "$repo" "$workflow_path"
    fi
  done <"$workflows"
done <<<"$repos"

if [ "$unknown" -ne 0 ]; then
  echo "workflow-execution-actors: UNKNOWN — some evidence could not be read or verified" >&2
  exit 2
fi
