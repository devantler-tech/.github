#!/usr/bin/env bash
# apply-workflow-execution-policies.sh — make the organization's Actions policies match the files.
#
# Usage:
#   apply-workflow-execution-policies.sh --org <org> [--dir <policies-dir>] [--check]
#
# Each *.json file in <policies-dir> (default: workflow-execution-policies/) is one organization
# Actions policy. Every file must pass validate-workflow-execution-policies.sh first. The
# review-only "exception" object is removed, and the rest is sent as the request body. A live
# organization policy belongs to a file when it has the file's exact name. Each file reports one of:
#   CREATED    no live policy had the name, so it was created
#   UPDATED    the live policy differed, so it was replaced
#   IN-SYNC    the live policy already matched
#   DRIFT      (--check only) the live policy is missing or differs; nothing was written
#   MISMATCH   after a write, GitHub returned something other than what was sent
#   FAILED     GitHub refused the write, or the live policy could not be read to compare
# A live organization policy that no file names is reported as UNMANAGED and left alone: nothing
# here deletes a policy, the same rule deploy/ follows.
#
# The list returns each policy in summary form, so a live policy is read in full before it is
# compared. Only the fields the files set are compared (name, enforcement, conditions and rules),
# with unordered lists sorted, so server-side fields such as id and timestamps never count as drift.
# An UPDATED or DRIFT line also prints what the live policy was.
# An update that omits workflow_path keeps the live policy's targeting, so removing workflow_path
# from a file reads back as MISMATCH until the policy is recreated.
#
# GH_TOKEN must be able to manage the organization's Actions policies.
#
# Exit codes: 0 every policy matches · 1 a file is invalid, a write failed, a read-back mismatched,
# or (--check) drift was found · 2 UNKNOWN: invalid usage, or the live policies could not be read
# completely. Nothing is written unless every file validates and every live policy was read.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
org=""
dir="$repo_root/workflow-execution-policies"
check=false
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org="${2:-}"; shift 2 || usage ;;
    --dir) dir="${2:-}"; shift 2 || usage ;;
    --check) check=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$org" ] || usage
[ -d "$dir" ] || { echo "apply-workflow-execution-policies: no directory $dir" >&2; exit 2; }

# A file that fails review is never sent, and neither is any other file: a half-applied set is
# harder to reason about than an unapplied one.
if ! validation="$(bash "$repo_root/scripts/validate-workflow-execution-policies.sh" "$dir" 2>&1)"; then
  printf '%s\n' "$validation"
  echo "apply-workflow-execution-policies: the policy files do not validate; nothing was applied" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One comparable shape for a file and for GitHub's copy of it.
normalize='
  def members: map({name, property_values: (.property_values // [] | sort)}) | sort;
  def condition:
    if .key == "repository_id" then .value = {repository_ids: (.value.repository_ids // [] | sort)}
    elif .key == "repository_property" then
      .value = {include: (.value.include // [] | members), exclude: (.value.exclude // [] | members)}
    else .value = {include: (.value.include // [] | sort), exclude: (.value.exclude // [] | sort)} end;
  def rule:
    if .type == "restrict_actions_actors" then
      {type, parameters: {allowed_actors: (.parameters.allowed_actors // [] | map({id, type}) | sort_by(.type, .id))}}
    elif .type == "restrict_action_events" then
      {type, parameters: {allowed_events: (.parameters.allowed_events // [] | sort)}}
    else {type, parameters} end;
  {
    name,
    enforcement,
    conditions: (.conditions // {} | with_entries(select(.value != null) | condition)),
    rules: (.rules // [] | map(rule) | sort_by(.type))
  }'

shopt -s nullglob
files=("$dir"/*.json)
desired="$tmp/desired"
mkdir "$desired"
names="$tmp/names"
: >"$names"
for f in "${files[@]}"; do
  base="${f##*/}"
  jq 'del(.exception)' "$f" >"$desired/$base"
  printf '%s\t%s\n' "$(jq -r .name "$f")" "$base" >>"$names"
done
# The name is what ties a file to its live policy, so two files may not share one.
duplicates="$(cut -f1 "$names" | sort | uniq -d)"
if [ -n "$duplicates" ]; then
  while IFS= read -r n; do echo "FAIL more than one file is named \"$n\""; done <<<"$duplicates"
  exit 1
fi

# Every live policy, page by page. A page that fails, a total that changes between pages, or a
# final count short of the total is UNKNOWN: comparing against a partial list would create a
# duplicate of a policy that exists on an unread page.
live="$tmp/live.json"
echo '[]' >"$live"
total=""
page=1
while :; do
  if ! response="$(gh api "orgs/$org/actions/policies?per_page=100&page=$page&has_parents=false" </dev/null 2>"$tmp/err")"; then
    echo "UNKNOWN could not list the organization's Actions policies (page $page): $(tr '\n' ' ' <"$tmp/err")" >&2
    exit 2
  fi
  if ! jq -e '(.total_count | type) == "number" and (.policies | type) == "array"' >/dev/null 2>&1 <<<"$response"; then
    echo "UNKNOWN the Actions policies list (page $page) is not the documented shape" >&2
    exit 2
  fi
  page_total="$(jq '.total_count' <<<"$response")"
  if [ -n "$total" ] && [ "$page_total" != "$total" ]; then
    echo "UNKNOWN the policy count changed from $total to $page_total while it was read" >&2
    exit 2
  fi
  total="$page_total"
  jq --argjson page "$(jq '.policies' <<<"$response")" '. + $page' "$live" >"$live.next"
  mv "$live.next" "$live"
  count="$(jq length "$live")"
  if [ "$count" -ge "$total" ] || [ "$(jq '.policies | length' <<<"$response")" -lt 100 ]; then
    break
  fi
  page=$((page + 1))
  if [ "$page" -gt 50 ]; then
    echo "UNKNOWN more than 50 pages of Actions policies" >&2
    exit 2
  fi
done
if [ "$count" -ne "$total" ]; then
  echo "UNKNOWN read $count of $total Actions policies" >&2
  exit 2
fi
# Policies set by an enterprise also apply here, but only the organization's own are ours to manage.
jq '[.[] | select((.source_type // "Organization") == "Organization")]' "$live" >"$live.next"
mv "$live.next" "$live"

# Two live policies with one managed name leave no single policy to update.
ambiguous="$(jq -r --rawfile names "$names" '
  ($names | split("\n") | map(select(. != "") | split("\t")[0])) as $managed
  | group_by(.name)[] | select(length > 1 and (.[0].name | IN($managed[]))) | .[0].name' "$live")"
if [ -n "$ambiguous" ]; then
  while IFS= read -r n; do echo "FAIL more than one live policy is named \"$n\"; nothing was applied"; done <<<"$ambiguous"
  exit 1
fi

failed=0
while IFS=$'\t' read -r name base; do
  want="$(jq -c "$normalize" "$desired/$base")"
  live_id="$(jq -r --arg name "$name" 'map(select(.name == $name)) | first | .id // empty' "$live")"
  have=""
  if [ -n "$live_id" ]; then
    # The list returns each policy in summary form, so compare the policy's own full read.
    if ! current="$(gh api "orgs/$org/actions/policies/$live_id" </dev/null 2>"$tmp/err")"; then
      echo "FAILED   $base: policy $live_id could not be read: $(tr '\n' ' ' <"$tmp/err")"
      failed=1
      continue
    fi
    have="$(jq -c "$normalize" <<<"$current" 2>/dev/null || true)"
    if [ "$have" = "$want" ]; then
      echo "IN-SYNC  $base"
      continue
    fi
  fi
  if [ "$check" = true ]; then
    if [ -z "$live_id" ]; then
      echo "DRIFT    $base: no live policy is named \"$name\""
    else
      echo "DRIFT    $base: the live policy (id $live_id) differs"
      echo "         want: $want"
      echo "         live: $have"
    fi
    failed=1
    continue
  fi
  if [ -z "$live_id" ]; then
    action=CREATED
    write=(--method POST "orgs/$org/actions/policies")
  else
    action=UPDATED
    write=(--method PUT "orgs/$org/actions/policies/$live_id")
  fi
  if ! written="$(gh api "${write[@]}" --input "$desired/$base" </dev/null 2>"$tmp/err")"; then
    echo "FAILED   $base: $(tr '\n' ' ' <"$tmp/err")"
    failed=1
    continue
  fi
  id="$(jq -r '.id // empty' <<<"$written" 2>/dev/null || true)"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "MISMATCH $base: GitHub's response carries no policy id"
    failed=1
    continue
  fi
  # Read it back rather than trusting the write's response: this is what proves GitHub stored
  # the policy as the file describes it.
  if ! stored="$(gh api "orgs/$org/actions/policies/$id" </dev/null 2>"$tmp/err")"; then
    echo "MISMATCH $base: policy $id could not be read back: $(tr '\n' ' ' <"$tmp/err")"
    failed=1
    continue
  fi
  got="$(jq -c "$normalize" <<<"$stored" 2>/dev/null || true)"
  if [ "$got" != "$want" ]; then
    echo "MISMATCH $base: policy $id was stored differently"
    echo "         sent:   $want"
    echo "         stored: $got"
    failed=1
    continue
  fi
  echo "$action  $base (id $id)"
  # What it was before the write, so the cause of drift can be read from the log.
  [ -z "$have" ] || echo "         was: $have"
done < <(sort -t $'\t' -k2 "$names")

jq -r --rawfile names "$names" '
  ($names | split("\n") | map(select(. != "") | split("\t")[0])) as $managed
  | .[] | select((.name | IN($managed[])) | not) | "UNMANAGED \(.name) (id \(.id)): no file names it; left alone"' "$live"

exit "$failed"
