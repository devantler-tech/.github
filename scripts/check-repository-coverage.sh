#!/usr/bin/env bash
#
# Reports every live, non-archived repository in the org that deploy/ does not
# declare.
#
# The declarative model can only govern the repositories it names. A repository
# created in the GitHub UI and never added to deploy/ gets no team grants, no
# labels and no settings, and every other check here is blind to it: the
# coverage test compares deploy/ with itself, and the drift check reads only the
# repositories deploy/ declares. This compares the live org with deploy/.
#
# Read-only. It never writes GitHub state.
#
# Environment:
#   REPOSITORY_COVERAGE_OWNER   org to list (default devantler-tech)
#   REPOSITORY_COVERAGE_RENDER  pre-rendered deploy/ manifest; default renders deploy/
#   REPOSITORY_COVERAGE_LIVE    file of "<name> <archived>" lines standing in for the
#                               live listing; default reads the GitHub API with a
#                               GitHub App installation token that must cover every
#                               repository. Used by tests to stay hermetic.
#
# Exit codes:
#   0  every live, non-archived repository is declared (or deliberately exempt)
#   1  at least one repository is undeclared, or an exemption is stale
#   2  the check could not be completed (fail closed)

set -euo pipefail

owner="${REPOSITORY_COVERAGE_OWNER:-devantler-tech}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="${REPOSITORY_COVERAGE_RENDER:-}"
live="${REPOSITORY_COVERAGE_LIVE:-}"
work="$(mktemp -d)"
audit_finished=0
audit_cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$work" || status=2
  if [[ "$audit_finished" != 1 ]]; then
    echo 'repository-coverage: UNKNOWN; audit did not finish' >&2
    status=2
  fi
  exit "$status"
}
trap 'audit_cleanup' EXIT

abort() {
  echo "repository-coverage: $*" >&2
  exit 2
}

# Live repositories deliberately left out of deploy/, as "<repo>". Each is
# declared intent with a tracked reason; the check fails on a stale entry, so
# this list cannot rot.
exemptions=(
  # actions is merged into this repository and then archived (#164). It is
  # declared in archived-repositories/ at that point (#240), not adopted first.
  "actions"
)

command -v yq >/dev/null || abort "required tool 'yq' not found"

if [[ -z "$render" ]]; then
  command -v kubectl >/dev/null || abort "required tool 'kubectl' not found"
  render="$work/render.yaml"
  kubectl kustomize "$repo_root/deploy" >"$render" || abort "kubectl kustomize deploy/ failed"
fi
[[ -s "$render" ]] || abort "rendered deploy/ is empty"

if [[ -z "$live" ]]; then
  command -v gh >/dev/null || abort "required tool 'gh' not found"
  live="$work/live.txt"
  # An App installation limited to selected repositories lists only those, and
  # the listing still succeeds. Declared repositories are usually among the
  # selected ones, so the unseen check below would pass while an undeclared
  # private repository outside the selection stays invisible. Only an
  # installation on every repository can see one created later. Reading the
  # installation's own selection needs no extra permission, where the org's
  # private repository count needs organization administration.
  selection="$(gh api 'installation/repositories?per_page=1' --jq '.repository_selection')" ||
    abort "reading the App installation's repository selection failed; run this with a GitHub App installation token"
  [[ "$selection" == "all" ]] ||
    abort "the App installation covers '${selection:-unknown}' repositories, not all, so it cannot see an undeclared repository outside its selection"
  # Captured, never streamed: a pagination that fails part-way exits non-zero
  # after printing the pages it did read, and a truncated list would pass.
  gh api --paginate "orgs/${owner}/repos?type=all&per_page=100" \
    --jq '.[] | "\(.name) \(.archived)"' >"$live" ||
    abort "listing the repositories of ${owner} failed"
fi
[[ -s "$live" ]] || abort "the live repository listing is empty"

# Every declared repository, archived or not, by its GitHub name.
yq -N 'select(.kind == "Repository") | .spec.forProvider.name' "$render" |
  grep -vE '^$|^null$|^---$' | sort -u >"$work/declared" ||
  abort "reading the declared repositories failed"

declared_count="$(wc -l <"$work/declared" | tr -d ' ')"
[[ "$declared_count" -ge 10 ]] ||
  abort "only ${declared_count} declared repositories rendered — refusing to run on a collapsed set"

# Every live line must be exactly "<name> <true|false>". A line that is not
# would drop out of the active set below without being reported, so reject it.
malformed="$(grep -cvE '^[A-Za-z0-9._-]+ (true|false)$' "$live" || true)"
[[ "$malformed" -eq 0 ]] ||
  abort "the live listing has ${malformed} line(s) that are not '<name> <true|false>'"

awk '$2 == "false" { print $1 }' "$live" | sort -u >"$work/live-active"
awk '{ print $1 }' "$live" | sort -u >"$work/live-all"

# The listing has to see every repository deploy/ declares, archived and private
# ones included. If it cannot, it could just as well be missing an undeclared
# private repository, and a clean result would be a pass over a partial org.
unseen="$(comm -23 "$work/declared" "$work/live-all")"
if [[ -n "$unseen" ]]; then
  while IFS= read -r repo; do
    echo "UNSEEN ${repo} — declared in deploy/ but absent from the live listing" >&2
  done <<<"$unseen"
  abort "the live listing does not cover every declared repository, so it cannot prove the rest are declared"
fi

is_exempt() {
  local needle="$1" entry
  ((${#exemptions[@]} == 0)) && return 1
  for entry in "${exemptions[@]}"; do
    [[ "$entry" == "$needle" ]] && return 0
  done
  return 1
}

findings=0

while IFS= read -r repo; do
  [[ -n "$repo" ]] || continue
  grep -Fxq "$repo" "$work/declared" && continue
  is_exempt "$repo" && continue
  echo "UNDECLARED ${repo} — live and not archived, but deploy/ does not declare it"
  findings=$((findings + 1))
done <"$work/live-active"

if ((${#exemptions[@]} > 0)); then
  for repo in "${exemptions[@]}"; do
    if grep -Fxq "$repo" "$work/declared" || ! grep -Fxq "$repo" "$work/live-active"; then
      echo "STALE-EXEMPTION ${repo} — it is declared, archived or gone; remove the exemption"
      findings=$((findings + 1))
    fi
  done
fi

live_count="$(wc -l <"$work/live-active" | tr -d ' ')"
if ((findings > 0)); then
  echo "repository-coverage: ${findings} finding(s) across ${live_count} live repositories" >&2
  audit_finished=1
  exit 1
fi

echo "repository-coverage: all ${live_count} live repositories are declared in deploy/"
audit_finished=1
