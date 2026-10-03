#!/usr/bin/env bash
# Detect lost comparisons and incomplete reads without touching organization state.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/check-organization-settings.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
[[ -f "$script" ]] || fail 'organization-settings audit is missing'
mkdir "$work/bin"
cat >"$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api orgs/devantler-tech' ]] || exit 99
printf '%s\n' "$*" >>"$CALLS"
cat "$RESPONSE"
exit "$API_STATUS"
SH
chmod +x "$work/bin/gh"
cat >"$work/policy.json" <<'JSON'
{"organization":"devantler-tech","settings":{"web_commit_signoff_required":true,"default_repository_permission":"read","members_can_create_repositories":true,"two_factor_requirement_enabled":true}}
JSON
cat >"$work/clean.json" <<'JSON'
{"login":"devantler-tech","id":178537263,"web_commit_signoff_required":true,"default_repository_permission":"read","members_can_create_repositories":true,"two_factor_requirement_enabled":true,"description":"API metadata is allowed"}
JSON
run_case() {
  local name="$1" response="$2" api_status="$3" want="$4" marker="$5" policy="${6:-$work/policy.json}" status=0
  : >"$work/calls"
  env -i PATH="$work/bin:$PATH" RESPONSE="$response" API_STATUS="$api_status" CALLS="$work/calls" \
    bash "$script" --policy "$policy" >"$work/log" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || fail "$name returned $status, expected $want: $(cat "$work/log")"
  grep -Fq "$marker" "$work/log" || fail "$name lost its classified verdict"
  if [[ "$want" != 0 ]]; then
    ! grep -q 'PASS' "$work/log" || fail "$name printed a clean verdict"
  fi
  echo "PASS: $name"
}
run_case clean "$work/clean.json" 0 0 'PASS; all 4 declared settings match'
for setting in web_commit_signoff_required members_can_create_repositories two_factor_requirement_enabled; do
  jq --arg key "$setting" '.[$key]=false' "$work/clean.json" >"$work/drift.json"
  run_case "drift-$setting" "$work/drift.json" 0 1 'DRIFT; 1 declared setting differs'
  jq --arg key "$setting" 'del(.[$key])' "$work/clean.json" >"$work/missing.json"
  run_case "missing-$setting" "$work/missing.json" 0 2 UNKNOWN
  jq --arg key "$setting" '.[$key]="true"' "$work/clean.json" >"$work/malformed.json"
  run_case "untyped-$setting" "$work/malformed.json" 0 2 UNKNOWN
done
jq '.default_repository_permission="write"' "$work/clean.json" >"$work/drift.json"
run_case drift-default-permission "$work/drift.json" 0 1 DRIFT
for mutation in 'del(.default_repository_permission)' '.default_repository_permission=1' '.default_repository_permission="unknown"' '.login="another-org"' 'del(.id)' '.id=0' '.id=1.5' '.id="178537263"'; do
  jq "$mutation" "$work/clean.json" >"$work/malformed.json"
  run_case "$mutation" "$work/malformed.json" 0 2 UNKNOWN
done
printf '{broken' >"$work/malformed.json"
run_case malformed-json "$work/malformed.json" 0 2 UNKNOWN
: >"$work/empty.json"
run_case empty-response "$work/empty.json" 0 2 UNKNOWN
cat "$work/clean.json" "$work/clean.json" >"$work/multiple.json"
run_case multiple-responses "$work/multiple.json" 0 2 UNKNOWN
run_case failed-plausible-clean "$work/clean.json" 44 2 UNKNOWN
run_case failed-plausible-drift "$work/drift.json" 44 2 UNKNOWN
for mutation in '.organization="other"' '.settings|=del(.two_factor_requirement_enabled)' '.settings.extra=true' '.settings.web_commit_signoff_required="true"' '.settings.default_repository_permission="unknown"' '.extra=true'; do
  jq "$mutation" "$work/policy.json" >"$work/bad-policy.json"
  run_case "invalid-policy-$mutation" "$work/clean.json" 0 2 UNKNOWN "$work/bad-policy.json"
  [[ ! -s "$work/calls" ]] || fail 'invalid policy contacted GitHub'
done
run_case unreadable-policy "$work/clean.json" 0 2 UNKNOWN "$work/missing-policy.json"
[[ ! -s "$work/calls" ]] || fail 'missing policy contacted GitHub'
echo 'PASS: organization settings compare real values; failures and partial reads never clear drift'
