#!/usr/bin/env bash
# Execute the real coverage client against documented installation/repository responses.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fixtures"
openssl genrsa -out "$work/test-key.pem" 2048 2>/dev/null
openssl rsa -in "$work/test-key.pem" -pubout -out "$work/test-public.pem" 2>/dev/null
GH_APP_PRIVATE_KEY="$(cat "$work/test-key.pem")"
export GH_APP_PRIVATE_KEY GH_APP_CLIENT_ID=Iv1.fixture GH_INSTALLATION_ID=77
export GH_TOKEN=fixture_installation_token
export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=schedule GITHUB_REPOSITORY=devantler-tech/.github GITHUB_REF=refs/heads/main
export GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/repository-coverage-check.yaml@refs/heads/main
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
# The documented legacy query has no selection field and jq returns null.
if [[ "$*" == 'api installation/repositories?per_page=1 --jq .repository_selection' ]]; then
  echo null
  exit 0
fi
[[ $# == 6 && "$1" == api && "$2" == --method && "$3" == GET && "$4" == --paginate && "$5" == --slurp &&
  "$6" == 'installation/repositories?per_page=100' ]] || exit 81
printf 'repositories\n' >>"$AUDIT_REQUESTS"
file="$AUDIT_FIXTURES/repositories.json"
if [[ "${AUDIT_CHANGED:-false}" == true && "$(grep -cFx repositories "$AUDIT_REQUESTS")" == 2 ]]; then
  file="$AUDIT_FIXTURES/after.json"
fi
cat "$file"
[[ "${AUDIT_FAILURE:-false}" != true ]] || exit 84
STUB
chmod +x "$work/bin/gh"
: >"$work/render.yaml"
for ((i = 1; i <= 10; i++)); do
  printf -- '---\nkind: Repository\nspec:\n  forProvider:\n    name: fixture-repo-%s\n' "$i" >>"$work/render.yaml"
done
reset_case() {
  unset AUDIT_CHANGED AUDIT_SELECTION_CHANGED AUDIT_PROOF_FAILURE AUDIT_FAILURE
  : >"$work/requests"
  jq -n '[range(1;11)|{id:.,name:("fixture-repo-"+tostring),full_name:("devantler-tech/fixture-repo-"+tostring),
    owner:{id:99,login:"devantler-tech"},private:(. % 2 == 0),archived:(. == 10)}] +
    [{id:11,name:"actions",full_name:"devantler-tech/actions",owner:{id:99,login:"devantler-tech"},private:false,archived:false}] |
    [{total_count:11,repositories:.[0:6]},{total_count:11,repositories:.[6:]}]' >"$work/fixtures/repositories.json"
  printf '%s\n' '{"id":77,"app_id":88,"target_id":99,"target_type":"Organization","account":{"id":99,"login":"devantler-tech","type":"Organization"},"repository_selection":"all","suspended_at":null,"suspended_by":null}' >"$work/fixtures/installation.json"
}
mutate() {
  jq "$2" "$1" >"$work/change.json"
  mv "$work/change.json" "$1"
}
check() {
  local expected="$1" label="$2" status=0
  PATH="$work/bin:$PATH" AUDIT_FIXTURES="$work/fixtures" AUDIT_REQUESTS="$work/requests" AUDIT_TEST_PUBLIC="$work/test-public.pem" \
    REPOSITORY_COVERAGE_RENDER="$work/render.yaml" bash "$root/scripts/check-repository-coverage.sh" >"$work/result" 2>&1 || status=$?
  [[ "$status" == "$expected" ]] || {
    echo "FAIL: $label expected $expected, got $status" >&2
    exit 1
  }
  if [[ "$status" != 0 ]] && grep -q 'all .* live repositories are declared' "$work/result"; then
    echo "FAIL: $label reported success with status $status" >&2
    exit 1
  fi
  echo "PASS: $label"
}
reset_case
check 0 'documented paginated response needs no invented selection field'
[[ "$(grep -cFx repositories "$work/requests")" == 2 && "$(grep -cFx installation-proof "$work/requests")" == 2 ]]
reset_case
mutate "$work/fixtures/installation.json" '.repository_selection="selected"'
check 2 'selected installation'
reset_case
mutate "$work/fixtures/installation.json" '.id=78'
check 2 'wrong installation identity'
reset_case
mutate "$work/fixtures/installation.json" '.suspended_at="now"'
check 2 'suspended installation'
reset_case
mutate "$work/fixtures/installation.json" '.account.login="outside"'
check 2 'wrong organization'
reset_case
mutate "$work/fixtures/installation.json" '.target_id=98'
check 2 'mismatched target'
reset_case
mutate "$work/fixtures/installation.json" 'del(.suspended_by)'
check 2 'missing suspension metadata'
reset_case
mutate "$work/fixtures/repositories.json" '.[1].total_count=12'
check 2 'changing page totals'
reset_case
mutate "$work/fixtures/repositories.json" '.[1].repositories=.[1].repositories[0:1]'
check 2 'truncated pagination'
reset_case
mutate "$work/fixtures/repositories.json" '.[0].repositories[1].id=1'
check 2 'duplicate identity'
reset_case
mutate "$work/fixtures/repositories.json" '.[0].repositories[1].name="fixture-repo-1"'
check 2 'duplicate name'
reset_case
mutate "$work/fixtures/repositories.json" '.[0].repositories[1].owner.id=98'
check 2 'cross-organization repository'
reset_case
mutate "$work/fixtures/repositories.json" '.[0].repositories[1].archived=null'
check 2 'unknown archive state'
reset_case
mutate "$work/fixtures/repositories.json" 'del(.[0].repositories[1].private)'
check 2 'unknown visibility'
reset_case
cp "$work/fixtures/repositories.json" "$work/fixtures/after.json"
mutate "$work/fixtures/after.json" '.[0].repositories[1].private=false'
AUDIT_CHANGED=true check 2 'census changed during coverage'
reset_case
cp "$work/fixtures/installation.json" "$work/fixtures/installation-after.json"
mutate "$work/fixtures/installation-after.json" '.repository_selection="selected"'
AUDIT_SELECTION_CHANGED=true check 2 'installation changed during coverage'
reset_case
AUDIT_FAILURE=true check 2 'partial API response followed by read failure'
reset_case
AUDIT_PROOF_FAILURE=true check 2 'installation metadata read failed'
reset_case
GH_APP_PRIVATE_KEY='' check 2 'missing proof key'
reset_case
GITHUB_REF=refs/heads/candidate check 2 'candidate source rejected'
reset_case
GITHUB_WORKFLOW_REF=other check 2 'unknown workflow rejected'
reset_case
GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch check 0 'combined manual context'
reset_case
GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main check 0 'combined scheduled context'
echo 'PASS: actual coverage client verifies authenticated metadata and a complete stable census'
