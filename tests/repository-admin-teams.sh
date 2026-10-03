#!/usr/bin/env bash
# Offline API evidence for the live admin-team policy; never uses credentials.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
guard="${1:-$root/scripts/check-repository-admin-teams.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fixtures/teams"
openssl genrsa -out "$work/test-key.pem" 2048 2>/dev/null
openssl rsa -in "$work/test-key.pem" -pubout -out "$work/test-public.pem" 2>/dev/null
GH_APP_PRIVATE_KEY="$(cat "$work/test-key.pem")"
export GH_APP_PRIVATE_KEY GH_APP_CLIENT_ID=Iv1.fixture GH_INSTALLATION_ID=77
export GH_TOKEN=fixture_installation_token
export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=devantler-tech/.github GITHUB_REF=refs/heads/main
export GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/repository-admin-team-audit.yaml@refs/heads/main
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 16 && "$1" == --disable && "$2" == --silent && "$3" == --show-error && "$4" == --fail &&
  "$5" == --request && "$6" == GET && "$7" == --max-time && "$8" == 30 && "$9" == --proto &&
  "${10}" == '=https' && "${11}" == --config && "${13}" == --url &&
  "${14}" == https://api.github.com/app/installations/77 && "${15}" == --output ]] || exit 85
[[ -z "${GH_APP_PRIVATE_KEY:-}" ]] || exit 86
jwt=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "${12}")
[[ "$jwt" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || exit 87
decode() {
  local part=$1
  while (( ${#part} % 4 != 0 )); do part="${part}="; done
  printf '%s' "$part" | tr '_-' '/+' | openssl base64 -d -A
}
decode "${jwt##*.}" >"$AUDIT_FIXTURES/signature"
printf '%s' "${jwt%.*}" >"$AUDIT_FIXTURES/signing-input"
openssl dgst -sha256 -verify "$AUDIT_TEST_PUBLIC" -signature "$AUDIT_FIXTURES/signature" \
  "$AUDIT_FIXTURES/signing-input" >/dev/null 2>&1 || exit 88
payload=${jwt#*.}; payload=${payload%.*}
decode "${jwt%%.*}" | jq -e '.alg == "RS256" and .typ == "JWT"' >/dev/null || exit 89
decode "$payload" | jq -e '.iss == "Iv1.fixture" and (.iat | type == "number") and
  (.exp | type == "number") and .exp - .iat == 600 and .iat <= now and .exp > now' >/dev/null || exit 89
printf 'installation-proof\n' >>"$AUDIT_REQUESTS"
file="$AUDIT_FIXTURES/installation.json"
if [[ "${AUDIT_SELECTION_CHANGED:-false}" == true && "$(grep -cFx installation-proof "$AUDIT_REQUESTS")" == 2 ]]; then
  file="$AUDIT_FIXTURES/installation-after.json"
fi
cp "$file" "${16}"
[[ "${AUDIT_PROOF_FAILURE:-false}" != true ]] || exit 22
STUB
chmod +x "$work/bin/curl"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 6 && "$1" == api && "$2" == --method && "$3" == GET && "$4" == --paginate && "$5" == --slurp ]] || exit 81
endpoint="$6"
printf '%s\n' "$endpoint" >>"$AUDIT_REQUESTS"
if [[ "$endpoint" == 'orgs/devantler-tech' ]]; then
  file="$AUDIT_FIXTURES/org.json"
elif [[ "$endpoint" == 'user/memberships/orgs/devantler-tech' ]]; then
  file="$AUDIT_FIXTURES/membership.json"
elif [[ "$endpoint" == 'orgs/devantler-tech/repos?type=all&per_page=100' ]]; then
  file="$AUDIT_FIXTURES/organization-repositories.json"
elif [[ "$endpoint" == 'installation/repositories?per_page=100' ]]; then
  file="$AUDIT_FIXTURES/repositories.json"
elif [[ "$endpoint" =~ ^repos/devantler-tech/([A-Za-z0-9._-]+)/teams\?per_page=100$ ]]; then
  file="$AUDIT_FIXTURES/teams/${BASH_REMATCH[1]}.json"
else
  echo fixture_private_sentinel >&2; exit 82
fi
[[ -f "$file" ]] || { echo fixture_private_sentinel >&2; exit 83; }
if [[ "${AUDIT_CHANGED:-false}" == true &&
  ( "$endpoint" == 'installation/repositories?per_page=100' || "$endpoint" == 'orgs/devantler-tech/repos?type=all&per_page=100' ) &&
  "$(grep -cFx "$endpoint" "$AUDIT_REQUESTS")" == 2 ]]; then
  file="$AUDIT_FIXTURES/after.json"
fi
if [[ "${AUDIT_TEAM_CHANGED:-false}" == true &&
  "$endpoint" == 'repos/devantler-tech/fixture_public/teams?per_page=100' &&
  "$(grep -cFx "$endpoint" "$AUDIT_REQUESTS")" == 2 ]]; then
  file="$AUDIT_FIXTURES/team-after.json"
fi
cat "$file"
if [[ "${AUDIT_FAILURE:-}" == "$endpoint" ]]; then
  echo fixture_private_sentinel >&2; exit 84
fi
STUB
chmod +x "$work/bin/gh"
reset_case() {
  unset AUDIT_FAILURE AUDIT_CHANGED AUDIT_TEAM_CHANGED AUDIT_SELECTION_CHANGED AUDIT_PROOF_FAILURE
  audit_arg=""
  : >"$work/requests"
  cat >"$work/fixtures/repositories.json" <<'JSON'
[{"total_count":4,"repositories":[
{"id":1,"name":"fixture_public","full_name":"devantler-tech/fixture_public","owner":{"id":99,"login":"devantler-tech"},"private":false,"archived":false},
{"id":2,"name":"fixture_private_sentinel","full_name":"devantler-tech/fixture_private_sentinel","owner":{"id":99,"login":"devantler-tech"},"private":true,"archived":false}]},
{"total_count":4,"repositories":[
{"id":3,"name":"actions","full_name":"devantler-tech/actions","owner":{"id":99,"login":"devantler-tech"},"private":false,"archived":false},
{"id":4,"name":"fixture_archived","full_name":"devantler-tech/fixture_archived","owner":{"id":99,"login":"devantler-tech"},"private":true,"archived":true}]}]
JSON
  printf '%s\n' '{"id":77,"app_id":88,"target_id":99,"target_type":"Organization","account":{"id":99,"login":"devantler-tech","type":"Organization"},"repository_selection":"all","suspended_at":null,"suspended_by":null}' >"$work/fixtures/installation.json"
  for repo in fixture_public fixture_private_sentinel actions; do
    printf '%s\n' '[[{"id":11,"slug":"admins","privacy":"secret","permission":"admin","permissions":{"admin":true}},{"id":12,"slug":"maintainers","privacy":"closed","permission":"custom","role_name":"custom","permissions":{"admin":false}}],[]]' >"$work/fixtures/teams/$repo.json"
  done
}
mutate() {
  local file="$1" program="$2"
  jq "$program" "$file" >"$work/mutated.json"
  mv "$work/mutated.json" "$file"
}
check() {
  local expected="$1" label="$2" code=0
  if [[ -n "$audit_arg" ]]; then
    PATH="$work/bin:$PATH" AUDIT_FIXTURES="$work/fixtures" AUDIT_REQUESTS="$work/requests" AUDIT_TEST_PUBLIC="$work/test-public.pem" \
      bash "$guard" "$audit_arg" >"$work/result" 2>&1 || code=$?
  else
    PATH="$work/bin:$PATH" AUDIT_FIXTURES="$work/fixtures" AUDIT_REQUESTS="$work/requests" AUDIT_TEST_PUBLIC="$work/test-public.pem" \
      bash "$guard" >"$work/result" 2>&1 || code=$?
  fi
  if grep -Eq 'fixture_(public|private|archived)|maintainers|repos/|18573307' "$work/result"; then
    echo "FAIL: $label exposed source details" >&2; exit 1
  fi
  [[ "$code" == "$expected" ]] || { echo "FAIL: $label expected $expected, got $code" >&2; exit 1; }
  echo "PASS: $label"
}
reset_case; check 0 'complete paginated census and effective permissions'
grep -qFx 'repos/devantler-tech/fixture_private_sentinel/teams?per_page=100' "$work/requests"
grep -qFx 'repos/devantler-tech/actions/teams?per_page=100' "$work/requests"
if grep -q 'fixture_archived/teams' "$work/requests"; then
  echo 'FAIL: archived repository was queried' >&2; exit 1
fi
documented_teams_case() {
  reset_case
  for repo in fixture_public fixture_private_sentinel actions; do
    mutate "$work/fixtures/teams/$repo.json" 'map(map(del(.permissions) | .permission=(if .slug == "admins" then "admin" else "pull" end)))'
  done
}
documented_teams_case; check 0 'documented singular permission response preserves complete audit'
for permission in maintain push pull triage; do
  documented_teams_case
  mutate "$work/fixtures/teams/fixture_public.json" ".[0][1].permission=\"$permission\""
  check 0 "documented $permission permission is non-admin"
done
documented_teams_case
mutate "$work/fixtures/teams/fixture_private_sentinel.json" '.[1]=[{id:13,slug:"fixture_private_sentinel",privacy:"closed",permission:"admin"}]'
check 1 'documented singular admin on a later page is a finding'
documented_teams_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][1].permission="custom-admin"'; check 2 'custom role without effective metadata is unknown'
documented_teams_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].permissions={admin:"true"}'; check 2 'malformed effective metadata cannot be hidden by singular permission'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].permissions.admin=false'; check 2 'conflicting known admin permission is unknown'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][1].permission="pull" | .[0][1].permissions.admin=true'; check 2 'conflicting known non-admin permission is unknown'
documented_teams_case
jq '.[0][1].permission="admin"' "$work/fixtures/teams/fixture_public.json" >"$work/fixtures/team-after.json"
export AUDIT_TEAM_CHANGED=true
check 2 'documented role change invalidates the repeated join'
reset_case
mutate "$work/fixtures/teams/fixture_private_sentinel.json" '.[1]=[{id:13,slug:"fixture_private_sentinel",privacy:"closed",permissions:{admin:true}}]'
check 1 'extra effective admin on a later page'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].slug="other-admin"'; check 1 'wrong sole admin team'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].permission="pull" | .[0][0].permissions.admin=false'; check 1 'no effective admin team'
reset_case; printf '%s\n' '[[]]' >"$work/fixtures/teams/fixture_public.json"; check 1 'empty team membership'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].role_name="custom" | .[0][0].permission="custom-admin"'; check 0 'custom role retains effective admin semantics'
reset_case; mutate "$work/fixtures/installation.json" '.repository_selection="selected"'; check 2 'selected installation cannot prove a census'
reset_case; mutate "$work/fixtures/repositories.json" '.[1].total_count=5'; check 2 'unstable repository total'
reset_case; mutate "$work/fixtures/repositories.json" '.[1].repositories=[]'; check 2 'truncated repository enumeration'
reset_case; mutate "$work/fixtures/repositories.json" '.[1].repositories[0].id=1'; check 2 'duplicate repository identity'
reset_case; mutate "$work/fixtures/repositories.json" '.[0].repositories[0].owner.login="other"'; check 2 'foreign repository owner'
reset_case; mutate "$work/fixtures/repositories.json" '.[0].repositories[0].private="false"'; check 2 'unknown privacy data'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[1]=[.[0][0]]'; check 2 'duplicate team across pages'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][1] |= del(.permissions.admin)'; check 2 'missing effective permission'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][1].permissions.admin="false"'; check 2 'unknown effective permission'
reset_case; printf '%s\n' '{}' >"$work/fixtures/teams/fixture_public.json"; check 2 'malformed team page wrapper'
reset_case; printf '%s\n' '[]' >>"$work/fixtures/teams/fixture_public.json"; check 2 'multiple JSON documents'
reset_case; rm "$work/fixtures/teams/fixture_private_sentinel.json"; check 2 'missing response never falls back to live API'
reset_case; export AUDIT_FAILURE='installation/repositories?per_page=100'; check 2 'partial census output followed by API failure'
reset_case; export AUDIT_FAILURE='repos/devantler-tech/fixture_public/teams?per_page=100'; check 2 'partial team output followed by API failure'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0].privacy="closed"'; check 1 'canonical admin cannot be an inheritable parent'
reset_case; mutate "$work/fixtures/teams/fixture_public.json" '.[0][0] |= del(.privacy)'; check 2 'unknown team visibility'
admin_case() {
  reset_case
  audit_arg=--organization-admin
  printf '%s\n' '[{"id":99,"login":"devantler-tech","public_repos":2,"total_private_repos":2}]' >"$work/fixtures/org.json"
  printf '%s\n' '[{"state":"active","role":"admin","organization":{"id":99,"login":"devantler-tech"}}]' >"$work/fixtures/membership.json"
  jq 'map(.repositories)' "$work/fixtures/repositories.json" >"$work/fixtures/organization-repositories.json"
}
admin_case; check 0 'explicit admin mode with independently complete public and private counts'
admin_case; mutate "$work/fixtures/org.json" '.[0] |= del(.total_private_repos)'; check 2 'missing private count is unknown'
admin_case; mutate "$work/fixtures/org.json" '.[0].total_private_repos=0'; check 2 'incomplete private census'
admin_case; mutate "$work/fixtures/membership.json" '.[0].role="member"'; check 2 'ordinary member cannot assert complete visibility'
admin_case; mutate "$work/fixtures/membership.json" '.[0].organization.id=100'; check 2 'membership belongs to another organization identity'
admin_case; mutate "$work/fixtures/organization-repositories.json" '.[0][0].owner.id=100'; check 2 'repository belongs to another organization identity'
admin_case; mutate "$work/fixtures/organization-repositories.json" '.[1].[] |= select(.private == false)'; check 2 'private repository omission'
admin_case; export AUDIT_FAILURE='orgs/devantler-tech/repos?type=all&per_page=100'; check 2 'partial admin census never reports success'
reset_case
sed 's/--paginate --slurp/--slurp/' "$guard" >"$work/no-pagination.sh"
original_guard="$guard"; guard="$work/no-pagination.sh"
check 2 'omitted pagination is rejected by the API fixture'
guard="$original_guard"
reset_case
jq '.[0].repositories[0].name="fixture_renamed" | .[0].repositories[0].full_name="devantler-tech/fixture_renamed"' "$work/fixtures/repositories.json" >"$work/fixtures/after.json"
export AUDIT_CHANGED=true
check 2 'same-count repository rename invalidates the join'
reset_case
jq '.[0].repositories[0].archived=true' "$work/fixtures/repositories.json" >"$work/fixtures/after.json"
export AUDIT_CHANGED=true
check 2 'archival during the join invalidates the result'
admin_case
jq '.[0][0].id=100' "$work/fixtures/organization-repositories.json" >"$work/fixtures/after.json"
export AUDIT_CHANGED=true
check 2 'same-count identity replacement invalidates the admin census'
reset_case
jq '.[1]=[{id:13,slug:"other-admin",privacy:"closed",permissions:{admin:true}}]' "$work/fixtures/teams/fixture_public.json" >"$work/fixtures/team-after.json"
export AUDIT_TEAM_CHANGED=true
check 2 'new admin assignment during the join invalidates the result'
reset_case
jq '.[0][0].permission="pull" | .[0][0].permissions.admin=false' "$work/fixtures/teams/fixture_public.json" >"$work/fixtures/team-after.json"
export AUDIT_TEAM_CHANGED=true
check 2 'admin permission removal during the join invalidates the result'
reset_case
jq '.[0][0].privacy="closed"' "$work/fixtures/teams/fixture_public.json" >"$work/fixtures/team-after.json"
export AUDIT_TEAM_CHANGED=true
check 2 'admin visibility change during the join invalidates the result'
reset_case
jq 'map(reverse) | reverse' "$work/fixtures/teams/fixture_public.json" >"$work/fixtures/team-after.json"
export AUDIT_TEAM_CHANGED=true
check 0 'pagination and team order changes preserve a stable canonical join'
reset_case; mutate "$work/fixtures/installation.json" 'del(.suspended_at)'; check 2 'missing installation suspension evidence'
reset_case; mutate "$work/fixtures/installation.json" '.suspended_at="2026-10-01T00:00:00Z"'; check 2 'suspended installation cannot prove coverage'
reset_case; mutate "$work/fixtures/installation.json" '.id=78'; check 2 'token mint and installation identity must match'
reset_case; mutate "$work/fixtures/installation.json" '.target_id=100'; check 2 'installation target and account identity must match'
reset_case; mutate "$work/fixtures/installation.json" '.account.id=100 | .target_id=100'; check 2 'repository census must match authenticated installation owner'
reset_case; export AUDIT_PROOF_FAILURE=true; check 2 'partial installation proof followed by HTTP failure'
reset_case
jq '.repository_selection="selected"' "$work/fixtures/installation.json" >"$work/fixtures/installation-after.json"
export AUDIT_SELECTION_CHANGED=true
check 2 'installation selection change invalidates the join'
reset_case; GITHUB_REF=refs/heads/fixture check 2 'installation mode requires reviewed main context'
reset_case; GITHUB_EVENT_NAME=pull_request check 2 'installation mode rejects a PR context'
reset_case; GH_APP_PRIVATE_KEY='' check 2 'missing App key cannot prove selection'
reset_case; GH_INSTALLATION_ID='77?redirect=1' check 2 'installation identity cannot redirect the credential request'
reset_case; mutate "$work/fixtures/installation.json" 'del(.suspended_by)'; check 2 'missing installation suspension actor evidence'
echo 'PASS: live admin-team audit accepts complete evidence and fails closed without exposing private details'
