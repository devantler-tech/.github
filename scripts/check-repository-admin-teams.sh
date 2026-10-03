#!/usr/bin/env bash
# Read-only live policy evidence. Public output contains aggregate results only.
# 0: complete compliant census; 1: policy findings; 2: incomplete/unknown evidence.
set +x
set -euo pipefail
umask 077
mode=installation
[[ $# == 0 || ($# == 1 && "$1" == --organization-admin) ]] || {
  echo 'usage: check-repository-admin-teams.sh [--organization-admin]' >&2
  exit 2
}
[[ $# == 0 ]] || mode=organization-admin
work="$(mktemp -d)"
audit_finished=0
# Bash 3.2 can report a nounset abort as zero; only a completed audit keeps its result.
audit_cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$work" || status=2
  if [[ "$audit_finished" != 1 ]]; then
    echo 'repository-admin-teams: UNKNOWN; audit did not finish' >&2
    status=2
  fi
  exit "$status"
}
trap 'audit_cleanup' EXIT
# Effective Boolean metadata supports custom roles. The documented singular
# field is sufficient for known built-in roles; malformed or conflicting rights
# and custom roles without effective metadata remain unknown.
cat >"$work/team-permissions.jq" <<'JQ'
def standard_permission: .permission | IN("admin","maintain","push","pull","triage");
def effective_admin:
  if has("permissions") and (.permissions | type != "object") then null
  elif (.permissions? // {} | has("admin")) then
    if (.permissions.admin | type != "boolean") then null
    elif standard_permission and ((.permission == "admin") != .permissions.admin) then null
    else .permissions.admin end
  elif standard_permission then .permission == "admin"
  else null end;
JQ
abort() {
  echo 'repository-admin-teams: UNKNOWN; complete live evidence unavailable' >&2
  exit 2
}
command -v gh >/dev/null || abort
command -v jq >/dev/null || abort
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/repository-census.sh
source "$repo_root/lib/repository-census.sh"
admin_visibility() {
  capture 'orgs/devantler-tech' "$work/org.json"
  capture 'user/memberships/orgs/devantler-tech' "$work/membership.json"
  jq -e -s 'length == 1 and (.[0] | type == "array" and length == 1 and
    .[0].login == "devantler-tech" and
    (.[0].id | type == "number" and . > 0 and . == floor) and
    (.[0].public_repos | type == "number" and . >= 0 and . == floor) and
    (.[0].total_private_repos | type == "number" and . >= 0 and . == floor))' \
    "$work/org.json" >/dev/null 2>"$work/parse-error" || abort
  org_id="$(jq -r '.[0].id' "$work/org.json")"
  jq -e -s --argjson org_id "$org_id" 'length == 1 and (.[0] | type == "array" and length == 1 and
    .[0].state == "active" and .[0].role == "admin" and
    .[0].organization.login == "devantler-tech" and .[0].organization.id == $org_id)' \
    "$work/membership.json" >/dev/null 2>"$work/parse-error" || abort
  public_count="$(jq -r '.[0].public_repos' "$work/org.json")"
  private_count="$(jq -r '.[0].total_private_repos' "$work/org.json")"
}
inventory='installation/repositories?per_page=100'
flatten='[.[].repositories[]]'
if [[ "$mode" == organization-admin ]]; then
  admin_visibility
  inventory='orgs/devantler-tech/repos?type=all&per_page=100'
  flatten='[.[][]]'
else
  prepare_installation_proof
fi
capture "$inventory" "$work/repositories.json"
validate_repositories "$work/repositories.json"
jq -r "$flatten | map(select(.archived == false)) | sort_by(.id) | .[].name" \
  "$work/repositories.json" >"$work/active" 2>"$work/parse-error" || abort
validate_teams() {
  jq -L "$work" -e -s 'include "team-permissions";
    length == 1 and (.[0] as $pages |
      ($pages | type == "array" and length > 0) and
      ($pages | all(type == "array" and length <= 100)) and
      ([$pages[][]] as $teams |
        ($teams | map(.id) | unique | length == ($teams | length)) and
        ($teams | map(.slug) | unique | length == ($teams | length)) and
        ($teams | all(type == "object" and
          (.id | type == "number" and . > 0 and . == floor) and
          (.slug | type == "string" and test("^[A-Za-z0-9_-]+$")) and
          (.privacy | IN("secret","closed")) and
          (effective_admin | type == "boolean")))))
  ' "$work/teams.json" >/dev/null 2>"$work/parse-error" || abort
}
canonical_teams() {
  jq -L "$work" -S 'include "team-permissions";
    [.[][] | {id,slug,privacy,admin:effective_admin}] | sort_by(.id)' \
    "$work/teams.json" >"$1" 2>"$work/parse-error" || abort
}
mkdir "$work/team-snapshots"
checked=0 findings=0
while IFS= read -r repo; do
  [[ -n "$repo" ]] || abort
  capture "repos/devantler-tech/$repo/teams?per_page=100" "$work/teams.json"
  validate_teams
  canonical_teams "$work/team-snapshots/$repo"
  if ! jq -e '[.[] | select(.admin == true)] | length == 1 and .[0].slug == "admins" and .[0].privacy == "secret"' \
    "$work/team-snapshots/$repo" >/dev/null 2>"$work/parse-error"; then
    findings=$((findings + 1))
  fi
  checked=$((checked + 1))
done <"$work/active"
# Rejoin every team assignment as well as the repository census. Changed identity,
# visibility or effective admin permission cannot support a stable policy verdict.
while IFS= read -r repo; do
  capture "repos/devantler-tech/$repo/teams?per_page=100" "$work/teams.json"
  validate_teams
  canonical_teams "$work/teams-after.canonical"
  cmp -s "$work/team-snapshots/$repo" "$work/teams-after.canonical" || abort
done <"$work/active"
# An inventory change during the join invalidates its completeness claim.
[[ "$mode" != organization-admin ]] || admin_visibility
capture "$inventory" "$work/repositories-after.json"
validate_repositories "$work/repositories-after.json"
for snapshot in repositories repositories-after; do
  jq -S "$flatten | map({id,name,full_name,owner:{id:.owner.id,login:.owner.login},archived,private}) | sort_by(.id)" \
    "$work/$snapshot.json" >"$work/$snapshot.canonical" 2>"$work/parse-error" || abort
done
cmp -s "$work/repositories.canonical" "$work/repositories-after.canonical" || abort
if [[ "$mode" == installation ]]; then
  installation_proof
  cmp -s "$work/installation-before.canonical" "$work/installation.canonical" || abort
fi
if ((findings > 0)); then
  echo "repository-admin-teams: $findings policy finding(s) across $checked active repositories" >&2
  audit_finished=1
  exit 1
fi
echo "repository-admin-teams: PASS; source=$mode; all $checked active repositories have exactly one Admins admin team"
audit_finished=1
