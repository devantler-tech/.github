#!/usr/bin/env bash
# Read-only live policy evidence. Public output contains aggregate results only.
# 0: complete compliant census; 1: policy findings; 2: incomplete/unknown evidence.
set +x
set -euo pipefail
umask 077
mode=installation
[[ $# == 0 || ( $# == 1 && "$1" == --organization-admin ) ]] || { echo 'usage: check-repository-admin-teams.sh [--organization-admin]' >&2; exit 2; }
[[ $# == 0 ]] || mode=organization-admin
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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
abort() { echo 'repository-admin-teams: UNKNOWN; complete live evidence unavailable' >&2; exit 2; }
command -v gh >/dev/null || abort
command -v jq >/dev/null || abort
capture() {
  gh api --method GET --paginate --slurp "$1" >"$2" 2>"$work/api-error" || abort
}
installation_proof() {
  curl --disable --silent --show-error --fail --request GET --max-time 30 --proto '=https' \
    --config "$work/app-request.conf" --url "https://api.github.com/app/installations/$installation_id" \
    --output "$work/installation.json" 2>"$work/api-error" || abort
  jq -e -s --argjson id "$installation_id" 'length == 1 and (.[0] |
    type == "object" and .id == $id and
    (.app_id | type == "number" and . > 0 and . == floor) and
    .repository_selection == "all" and .target_type == "Organization" and
    .account.type == "Organization" and .account.login == "devantler-tech" and
    (.account.id | type == "number" and . > 0 and . == floor) and .target_id == .account.id and
    has("suspended_at") and .suspended_at == null and has("suspended_by") and .suspended_by == null)' \
    "$work/installation.json" >/dev/null 2>"$work/parse-error" || abort
  org_id="$(jq -r '.account.id' "$work/installation.json")"
  jq -S '{id,app_id,target_id,target_type,account:{id:.account.id,login:.account.login,type:.account.type},repository_selection,suspended_at,suspended_by}' \
    "$work/installation.json" >"$work/installation.canonical" 2>"$work/parse-error" || abort
}
prepare_installation_proof() {
  # Only the reviewed main workflow supplies an unrestricted, read-only installation
  # token. An arbitrary caller token cannot establish complete installation visibility.
  [[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
    "${GITHUB_REPOSITORY:-}" == devantler-tech/.github &&
    "${GITHUB_REF:-}" == refs/heads/main &&
    "${GITHUB_WORKFLOW_REF:-}" == devantler-tech/.github/.github/workflows/repository-admin-team-audit.yaml@refs/heads/main &&
    -n "${GH_TOKEN:-}" && -n "${GH_APP_PRIVATE_KEY:-}" &&
    "${GH_APP_CLIENT_ID:-}" =~ ^(Iv[0-9A-Za-z._-]+|[0-9]+)$ &&
    "${GH_INSTALLATION_ID:-}" =~ ^[1-9][0-9]*$ ]] || abort
  command -v openssl >/dev/null || abort
  command -v curl >/dev/null || abort
  installation_id="$GH_INSTALLATION_ID"
  printf '%s' "$GH_APP_PRIVATE_KEY" >"$work/app-key.pem"
  unset GH_APP_PRIVATE_KEY
  local now header payload signature jwt
  now="$(date +%s)"
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  payload=$(jq -cn --arg iss "$GH_APP_CLIENT_ID" --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
    '{iss:$iss,iat:$iat,exp:$exp}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  signature=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$work/app-key.pem" 2>"$work/parse-error" \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  rm "$work/app-key.pem"
  jwt="$header.$payload.$signature"
  printf '::add-mask::%s\n' "$jwt"
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2026-03-10"\n' \
    "$jwt" >"$work/app-request.conf"
  installation_proof
  cp "$work/installation.canonical" "$work/installation-before.canonical"
}
validate_repositories() {
  jq -e -s --arg mode "$mode" --argjson public "${public_count:-0}" --argjson private "${private_count:-0}" --argjson org_id "${org_id:-0}" '
    length == 1 and (.[0] as $pages |
      ($pages | type == "array" and length > 0) and
      (if $mode == "installation" then
        ($pages | all(type == "object" and
          (.total_count | type == "number" and . > 0 and . == floor) and
          (.repositories | type == "array" and length <= 100))) and
        ($pages | map(.total_count) | unique | length == 1)
       else ($pages | all(type == "array" and length <= 100)) end) and
      ((if $mode == "installation" then [$pages[].repositories[]] else [$pages[][]] end) as $repos |
        (if $mode == "installation" then ($repos | length == $pages[0].total_count)
         else ($repos | length == ($public + $private)) and
           ([$repos[] | select(.private == false)] | length == $public) and
           ([$repos[] | select(.private == true)] | length == $private) end) and
        ($repos | map(.id) | unique | length == ($repos | length)) and
        ($repos | map(.name) | unique | length == ($repos | length)) and
        ($repos | map(.owner.id) | unique | length == 1) and
        ($repos | all(type == "object" and
          (.id | type == "number" and . > 0 and . == floor) and
          (.name | type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..") and
          .owner.login == "devantler-tech" and
          (.owner.id | type == "number" and . > 0 and . == floor) and
          .owner.id == $org_id and
          .full_name == ("devantler-tech/" + .name) and
          (.archived | type == "boolean") and (.private | type == "boolean")))))
  ' "$1" > /dev/null 2>"$work/parse-error" || abort
}
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
  exit 1
fi
echo "repository-admin-teams: PASS; source=$mode; all $checked active repositories have exactly one Admins admin team"
