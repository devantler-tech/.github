#!/usr/bin/env bash
# Execute the real coverage client against documented installation/repository responses.
# The token comes from the GitHub token broker (devantler-tech/monorepo ADR 0020), so there is no
# App key or JWT: completeness is proven from the organization's installation list.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/fixtures"
export GH_TOKEN=fixture_installation_token
export GITHUB_ACTIONS=true GITHUB_EVENT_NAME=schedule GITHUB_REPOSITORY=devantler-tech/.github GITHUB_REF=refs/heads/main
export GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/repository-coverage-check.yaml@refs/heads/main
# The App-JWT installation lookup is retired: any curl call fails the case.
printf '#!/usr/bin/env bash\nexit 85\n' >"$work/bin/curl"
chmod +x "$work/bin/curl"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# == 6 && "$1" == api && "$2" == --method && "$3" == GET && "$4" == --paginate && "$5" == --slurp &&
  "$6" == 'orgs/devantler-tech/installations?per_page=100' ]]; then
  printf 'installation-proof\n' >>"$AUDIT_REQUESTS"
  file="$AUDIT_FIXTURES/installations.json"
  if [[ "${AUDIT_SELECTION_CHANGED:-false}" == true && "$(grep -cFx installation-proof "$AUDIT_REQUESTS")" == 2 ]]; then
    file="$AUDIT_FIXTURES/installations-after.json"
  fi
  cat "$file"
  [[ "${AUDIT_PROOF_FAILURE:-false}" != true ]] || exit 22
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
    [{id:11,name:"retired-fixture",full_name:"devantler-tech/retired-fixture",owner:{id:99,login:"devantler-tech"},private:false,archived:true}] |
    [{total_count:11,repositories:.[0:6]},{total_count:11,repositories:.[6:]}]' >"$work/fixtures/repositories.json"
  jq -n '[{total_count:3,installations:[
    {id:77,app_id:88,app_slug:"botantler-1",target_id:99,target_type:"Organization",
      account:{id:99,login:"devantler-tech",type:"Organization"},repository_selection:"all",suspended_at:null},
    {id:78,app_id:89,app_slug:"botantler-2",target_id:99,target_type:"Organization",
      account:{id:99,login:"devantler-tech",type:"Organization"},repository_selection:"all",suspended_at:null},
    {id:79,app_id:90,app_slug:"other-app",target_id:99,target_type:"Organization",
      account:{id:99,login:"devantler-tech",type:"Organization"},repository_selection:"selected",suspended_at:null}]}]' \
    >"$work/fixtures/installations.json"
}
mutate() {
  jq "$2" "$1" >"$work/change.json"
  mv "$work/change.json" "$1"
}
check() {
  local expected="$1" label="$2" status=0
  PATH="$work/bin:$PATH" AUDIT_FIXTURES="$work/fixtures" AUDIT_REQUESTS="$work/requests" \
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
installations="$work/fixtures/installations.json"
reset_case
check 0 'documented responses prove both broker Apps cover all repositories'
[[ "$(grep -cFx repositories "$work/requests")" == 2 && "$(grep -cFx installation-proof "$work/requests")" == 2 ]]
reset_case
mutate "$installations" '.[0].installations[0].repository_selection="selected"'
check 2 'botantler-1 limited to selected repositories'
reset_case
mutate "$installations" '.[0].installations[1].repository_selection="selected"'
check 2 'botantler-2 limited to selected repositories'
reset_case
mutate "$installations" '.[0].installations |= map(select(.app_slug != "botantler-2"))'
check 2 'botantler-2 not installed'
reset_case
mutate "$installations" '.[0].installations += [.[0].installations[0]]'
check 2 'duplicate botantler installation'
reset_case
mutate "$installations" '.[0].installations[1].suspended_at="now"'
check 2 'suspended installation'
reset_case
mutate "$installations" '.[0].installations[0].account.login="outside"'
check 2 'wrong organization'
reset_case
mutate "$installations" '.[0].installations[0].target_id=98'
check 2 'mismatched target'
reset_case
mutate "$installations" 'del(.[0].installations[0].suspended_at)'
check 2 'missing suspension metadata'
reset_case
mutate "$installations" '.[0].installations[1].account.id=98 | .[0].installations[1].target_id=98'
check 2 'Apps installed on different organizations'
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
cp "$installations" "$work/fixtures/installations-after.json"
mutate "$work/fixtures/installations-after.json" '.[0].installations[1].repository_selection="selected"'
AUDIT_SELECTION_CHANGED=true check 2 'installation changed during coverage'
reset_case
AUDIT_FAILURE=true check 2 'partial API response followed by read failure'
reset_case
AUDIT_PROOF_FAILURE=true check 2 'installation list read failed'
reset_case
GH_TOKEN='' check 2 'missing broker token'
reset_case
GITHUB_REF=refs/heads/candidate check 2 'candidate source rejected'
reset_case
GITHUB_WORKFLOW_REF=other check 2 'unknown workflow rejected'
reset_case
GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch check 0 'combined manual context'
reset_case
GITHUB_WORKFLOW_REF=devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main check 0 'combined scheduled context'
echo 'PASS: actual coverage client verifies both broker Apps cover every repository and a complete stable census'
