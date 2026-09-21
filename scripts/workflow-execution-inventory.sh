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
#   deployment           a job targets an environment, a step's run script contains a deploy
#                        command, or a step deploys a live site (actions/deploy-pages). Run scripts
#                        are matched as text, not parsed, so a deploy command that is only printed
#                        (echo kubectl apply) still counts. That over-reporting is deliberate: this
#                        inventory exists to find every path that could deploy, and a missed one
#                        costs more than a row a reader clears by reading it.
#   publication          a packages, id-token or attestations write scope (or write-all), or a step
#                        uses a release, image-push, signing or package-publish tool. Tools are matched
#                        as text across run scripts and action references, so a printed publish
#                        command (echo npm publish) still counts, for the same reason as deployment.
#   release-unconfirmed  the file or display name says it publishes, releases or deploys, but the
#                        workflow shows no deployment or publication evidence — read it to decide
#   reusable-caller      a job calls a reusable workflow and this file shows no deployment or
#                        publication evidence — the called workflow's steps decide, so read it
#   reusable             workflow_call
#   scheduled            schedule
#   ci                   none of the above
# deployment and publication come from what the workflow does, not from its name. A job that calls a
# reusable workflow hides that workflow's steps, so read the called workflow for those.
# Scope: each repository's DEFAULT BRANCH only. A workflow that exists only on another branch or tag
# can still run there and is not listed; this is a default-branch inventory, not a complete one.
#
# Exit codes: 0 complete · 2 UNKNOWN — at least one repository, listing or workflow could not be
# read or parsed. Those rows say UNKNOWN; a partial inventory is never reported as complete.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

unknown=0

# events <file> — one event name per line. Fails when yq fails, even after partial output
# (a malformed later document in a multi-document file).
events() {
  local out
  # GitHub reads one workflow document per file; merging several would invent a workflow.
  [ "$(yq ea '[.] | length' "$1" 2>/dev/null)" = 1 ] || return 1
  out="$(yq -r '.on | ((select(tag == "!!str")), (select(tag == "!!seq") | .[]),
    (select(tag == "!!map") | keys | .[]))' "$1" 2>/dev/null)" || return 1
  grep -v '^$' <<<"$out" | sort -u || true
}

# Commands that change a running environment, and tools that publish an artifact or release.
deploy_commands='kubectl (apply|patch|rollout|set|delete)|helm (upgrade|install)|terraform apply|tofu apply|pulumi up|flux reconcile|ksail[^|]* (workload (push|reconcile)|cluster (create|update))|aws [a-z-]+ (deploy|update-service)|wrangler (deploy|publish)'
# Actions that deploy. Matched against `uses:` references only, so a shell step that merely names one
# (`echo actions/deploy-pages`) is not mistaken for running it.
deploy_actions='^actions/deploy-pages(@|$)'
publish_tools='goreleaser|semantic-release|gh release (create|upload|edit)|docker (push|buildx build[^|]*--push)|cosign sign|npm publish|dotnet nuget push|oras push|softprops/action-gh-release'

# evidence <file> — prints "deployment" and/or "publication", one per line, from what the workflow
# does rather than what it is called. Fails when the file cannot be read.
evidence() {
  local file="$1" text runs uses perms envs callers pushes seen=""
  # Every step command and every action or reusable workflow a job uses.
  text="$(yq -r '.jobs[]? | (.steps[]?.run, .steps[]?.uses, .uses) | select(. != null)' "$file" 2>/dev/null)" ||
    return 1
  # A commented-out line is not something the workflow does.
  text="$(grep -vE '^[[:space:]]*#' <<<"$text" || true)"
  # Shell commands and action references, kept apart for the deployment test.
  runs="$(yq -r '.jobs[]? | .steps[]?.run | select(. != null)' "$file" 2>/dev/null)" || return 1
  runs="$(grep -vE '^[[:space:]]*#' <<<"$runs" || true)"
  uses="$(yq -r '.jobs[]? | (.steps[]?.uses, .uses) | select(. != null)' "$file" 2>/dev/null)" || return 1
  # Each job's effective write scopes: its own permissions replace the workflow's, and a job without
  # any inherits them. `write-all` grants every scope.
  # shellcheck disable=SC2016 # $wp is a yq variable, not a shell one.
  perms="$(yq -r '.permissions as $wp | .jobs[]? | (.permissions // $wp) | select(. != null) |
    ((select(tag == "!!str")), (select(tag == "!!map") | to_entries | .[] | select(.value == "write") | .key))' \
    "$file" 2>/dev/null)" || return 1
  envs="$(yq -r '[.jobs[]? | select(has("environment"))] | length' "$file" 2>/dev/null)" || return 1
  callers="$(yq -r '[.jobs[]? | select(has("uses"))] | length' "$file" 2>/dev/null)" || return 1
  # docker/build-push-action only builds unless its `push` input is set (the default is false). An
  # expression may evaluate to true, so anything but an explicit false counts as a push.
  pushes="$(yq -r '[.jobs[]?.steps[]? | select((.uses // "") | test("^docker/build-push-action(@|$)")) |
    select(.with.push != null and (.with.push | tostring | downcase) != "false")] | length' "$file" 2>/dev/null)" ||
    return 1
  if [ "${envs:-0}" != 0 ] || grep -qiE "$deploy_commands" <<<"$runs" ||
    grep -qE "$deploy_actions" <<<"$uses"; then
    echo deployment
    seen=1
  fi
  # contents: write is left out: bots that only commit formatting or changelogs need it too.
  if grep -qxE 'write-all|packages|id-token|attestations' <<<"$perms" ||
    grep -qiE "$publish_tools" <<<"$text" || [ "${pushes:-0}" != 0 ]; then
    echo publication
    seen=1
  fi
  # A called workflow's steps are not in this file, so no evidence here proves nothing.
  if [ -z "$seen" ] && [ "${callers:-0}" != 0 ]; then
    echo reusable-caller
  fi
  return 0
}

# classify <file> <workflow-name> — prints "<events>\t<exposure>" or UNKNOWN.
classify() {
  local file="$1" name="$2" evs display found classes=()
  evs="$(events "$file")" || evs=""
  found="$(evidence "$file")" || evs=""
  if [ -z "$evs" ]; then
    printf 'UNKNOWN\tUNKNOWN'
    return
  fi
  display="$(yq -r '.name // ""' "$file" 2>/dev/null || true)"
  grep -qxE 'pull_request_target|workflow_run' <<<"$evs" && classes+=(privileged-trigger)
  grep -qxE 'workflow_dispatch|repository_dispatch' <<<"$evs" && classes+=(manual-entry)
  grep -qx deployment <<<"$found" && classes+=(deployment)
  grep -qx publication <<<"$found" && classes+=(publication)
  # A release-sounding name with no evidence is reported for reading, never guessed either way.
  if ! grep -qxE 'deployment|publication' <<<"$found" &&
    grep -qiE '(^|[^a-z])(cd($|[^a-z])|deploy|publish|release)' <<<"$name $display"; then
    classes+=(release-unconfirmed)
  fi
  grep -qx reusable-caller <<<"$found" && classes+=(reusable-caller)
  grep -qx 'workflow_call' <<<"$evs" && classes+=(reusable)
  grep -qx 'schedule' <<<"$evs" && classes+=(scheduled)
  [ "${#classes[@]}" -eq 0 ] && classes=(ci)
  local IFS=,
  printf '%s\t%s' "$(tr '\n' ',' <<<"$evs" | sed 's/,$//')" "${classes[*]}"
}

# inventory_dir <repo> <dir> <policies> — one row per workflow file in <dir>.
inventory_dir() {
  local repo="$1" dir="$2" policies="$3" f row
  # An unlistable directory expands no glob, which would read as "no workflows".
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\t%s\n' "$repo" "$policies"
    unknown=1
    return
  fi
  # GitHub runs dot-prefixed workflow files too, and a bare glob skips them.
  for f in "$dir"/*.yml "$dir"/*.yaml "$dir"/.*.yml "$dir"/.*.yaml; do
    [ -f "$f" ] || continue
    # classify runs in a subshell, so its verdict is read from the row, not from a variable.
    row="$(classify "$f" "$(basename "$f")")"
    case "$row" in UNKNOWN*) unknown=1 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$repo" "$(basename "$f")" "$row" "$policies"
  done
}

inventory_org() {
  local org="$1" repos repo policies listing name sha
  local listed expected
  listed="$(gh api "orgs/$org/repos" --paginate --jq '.[] | "\(.archived) \(.name)"')" ||
    { echo "workflow-execution-inventory: UNKNOWN — cannot list $org repositories" >&2; exit 2; }
  # A token restricted to selected repositories lists only those, and succeeds. Compare the listing
  # with the organisation's own count; a token that cannot see the private count is UNKNOWN too.
  expected="$(gh api "orgs/$org" --jq 'if .total_private_repos == null then "" else .public_repos + .total_private_repos end')" ||
    expected=""
  if [ -z "$expected" ] || [ "$(grep -c . <<<"$listed")" != "$expected" ]; then
    echo "workflow-execution-inventory: UNKNOWN — listed $(grep -c . <<<"$listed") of ${expected:-an unknown number of} $org repositories; the token cannot see them all" >&2
    exit 2
  fi
  repos="$(sed -n 's/^false //p' <<<"$listed")"
  # The count check above proved the listing complete, so no active repository is a complete answer.
  [ -n "$repos" ] || return 0
  # Global, not local: the EXIT trap runs after this function has returned.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  while IFS= read -r repo; do
    policies="$(gh api "repos/$org/$repo/actions/policies" --jq '.total_count' 2>/dev/null)" ||
      { policies=UNKNOWN; unknown=1; }
    # Pin every read to one commit, so a push during the scan cannot split the listing from the files.
    # An empty repository has no commit; GitHub answers with 409 and it has no workflows.
    if ! sha="$(gh api "repos/$org/$repo/commits/HEAD" --jq '.sha' 2>"$tmp/err")" || [ -z "$sha" ]; then
      grep -q 'HTTP 409' "$tmp/err" && continue
      printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\t%s\n' "$repo" "$policies"
      unknown=1
      continue
    fi
    if ! listing="$(gh api "repos/$org/$repo/contents/.github/workflows?ref=$sha" \
      --jq 'if length >= 1000 then "TRUNCATED" else (.[] | select(.type == "file") | .name) end' 2>"$tmp/err")"; then
      # The commit was readable, so a 404 here means the directory does not exist at that commit.
      grep -q 'HTTP 404' "$tmp/err" && continue
      printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\t%s\n' "$repo" "$policies"
      unknown=1
      continue
    fi
    # The contents API lists at most 1,000 entries per directory, so a full page may be partial.
    if [ "$listing" = TRUNCATED ]; then
      printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\t%s\n' "$repo" "$policies"
      unknown=1
      continue
    fi
    rm -rf "${tmp:?}/wf" && mkdir "$tmp/wf"
    while IFS= read -r name; do
      case "$name" in *.yml | *.yaml) ;; *) continue ;; esac
      gh api "repos/$org/$repo/contents/.github/workflows/$name?ref=$sha" \
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
