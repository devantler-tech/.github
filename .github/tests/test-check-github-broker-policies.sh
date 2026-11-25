#!/usr/bin/env bash
# Exercise the organization-required GitHub token broker policy check
# (.github/workflows/check-github-broker-policies.yaml, devantler-tech/monorepo
# ADR 0020) against real policy files: the accepted shapes pass, and every way a
# policy could admit an outside caller or take the wrong App fails for its own
# reason. Also pins the workflow shape a required workflow needs.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/check-github-broker-policies.yaml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cases=0
fail() {
  printf 'test-check-github-broker-policies: %s\n' "$*" >&2
  exit 1
}

# --- The workflow's shape -------------------------------------------------------
[[ "$(yq -o=json -I=0 '.on | keys' "$workflow")" == '["pull_request","merge_group"]' ]] ||
  fail 'a required-only workflow triggers on pull_request and merge_group, and nothing calls it'
[[ "$(yq -o=json -I=0 '.permissions' "$workflow")" == '{}' ]] || fail 'top-level permissions must be empty'
[[ "$(yq '.jobs | keys | join(",")' "$workflow")" == check ]] || fail 'expected exactly one job, check'
[[ "$(yq -o=json -I=0 '.jobs.check.permissions' "$workflow")" == '{"contents":"read"}' ]] ||
  fail 'the check job may only read contents'
[[ "$(yq '[.jobs.check, .jobs.check.steps[]] | map(has("if")) | any' "$workflow")" == false ]] ||
  fail 'nothing in a required workflow may be skipped: a skipped run can leave the rule unsatisfied'
[[ "$(yq '.jobs.check.steps[0].uses' "$workflow")" == step-security/harden-runner@* ]] || fail 'harden-runner must run first'
[[ "$(yq '.jobs.check.steps[] | select(.uses == "actions/checkout@*") | .with["persist-credentials"]' "$workflow")" == false ]] ||
  fail 'the checkout must not persist credentials'
yq '.jobs.check.steps[] | select(.name == "🔐 Check broker trust policies") | .run' "$workflow" >"$tmp/check.sh"
[[ -s "$tmp/check.sh" ]] || fail 'the check step has no script'

# --- The rules, against real policy files ----------------------------------------
readonly issuer='issuer: https://token.actions.githubusercontent.com'
readonly owner='  repository_owner_id: "178524219"'
readonly read_only=$'permissions:\n  contents: read'
readonly writes=$'permissions:\n  contents: write\n  pull_requests: write'
readonly release_workflow='  job_workflow_ref: devantler-tech/\.github/\.github/workflows/create-release\.yaml@refs/heads/main'
# policy <issuer line> <claim lines> <permissions> [extra top-level lines]
policy() {
  printf '%s\n' '---' "$1" 'subject: repo:devantler-tech/platform:ref:refs/heads/main' 'claim_pattern:' "$2" "$3" "${4:-}"
}
# expect <exit status> <message substring or empty> <case> <policy text>
expect() {
  local want="$1" message="$2" name="$3" status=0
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/.github/chainguard"
  if [[ -n "$4" ]]; then
    printf '%s\n' "$4" >"$tmp/repo/.github/chainguard/case.sts.yaml"
  fi
  (cd "$tmp/repo" && GITHUB_REPOSITORY="${repository:-devantler-tech/platform}" bash "$tmp/check.sh") >"$tmp/out" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || { cat "$tmp/out" >&2; fail "$name: expected exit $want, got $status"; }
  [[ -z "$message" ]] || grep -Fq -- "$message" "$tmp/out" || { cat "$tmp/out" >&2; fail "$name: missing '$message'"; }
  cases=$((cases + 1))
}

expect 0 '0 broker trust policies' 'a repository without policies' ''
expect 0 '1 broker trust policies admit only reviewed callers' 'a read-only devantler-tech policy without an App pin' \
  "$(policy "$issuer" "$owner" "$read_only")"
# botantler-1 and botantler-2 are interchangeable, so a policy names no App. A pin to one of
# them still passes until each policy drops its own; any other App never does.
expect 0 '' 'a write policy with no App, for either App to mint' "$(policy "$issuer" "$owner" "$writes")"
expect 0 '' 'the shared release workflow with no App' \
  "$(policy "$issuer" "$owner"$'\n'"$release_workflow" "$writes" 'caller_repository: true')"
expect 0 '' 'a write policy still pinned to botantler-2' "$(policy "$issuer" "$owner" "$writes" 'app: botantler-2')"
expect 0 '' 'a write policy still pinned to botantler-1' "$(policy "$issuer" "$owner" "$writes" 'app: botantler-1')"
# Both subject forms a devantler-tech repository can issue: name-only, and the immutable form with
# the owner and repository IDs.
readonly any_caller='subject_pattern: repo:devantler-tech(/[A-Za-z0-9._-]+|@178524219/[A-Za-z0-9._-]+@[0-9]+):ref:refs/heads/main'

expect 1 'must pin claim_pattern.repository_owner_id' 'no caller pin' "$(policy "$issuer" '  ref: refs/heads/main' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'another organization' \
  "$(policy "$issuer" '  repository_owner_id: "1"' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'any owner' "$(policy "$issuer" '  repository_owner_id: ".*"' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'an owner pattern wider than the ID' \
  "$(policy "$issuer" '  repository_owner_id: "178524219|1"' "$read_only")"
expect 1 'claim_pattern must map claim names to strings' 'the owner ID as a number' \
  "$(policy "$issuer" '  repository_owner_id: 178524219' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'an unlisted repository ID instead of the owner' \
  "$(policy "$issuer" '  repository_id: "494599576"' "$read_only")"
expect 1 'name the issuer and App exactly' 'an issuer pattern' \
  "$(policy 'issuer_pattern: https://.*' "$owner" "$read_only")"
expect 1 'must accept exactly the GitHub Actions issuer' 'another issuer' \
  "$(policy 'issuer: https://issuer.example.com' "$owner" "$read_only")"
expect 1 'name the issuer and App exactly' 'an App pattern' "$(policy "$issuer" "$owner" "$writes" 'app_pattern: botantler-.*')"
expect 1 'pins unknown App' 'an unknown App' "$(policy "$issuer" "$owner" "$writes" 'app: devantler-tech-engineering')"
expect 1 'outside the reviewed allowlist' 'repository administration outside devantler-tech/.github' \
  "$(policy "$issuer" "$owner" $'permissions:\n  administration: read' 'app: botantler-2')"
expect 1 'outside the reviewed allowlist' 'organization administration outside devantler-tech/.github' \
  "$(policy "$issuer" "$owner" $'permissions:\n  organization_administration: write' 'app: botantler-2')"
expect 1 'holds 2 YAML documents' 'a second document' \
  "$(policy "$issuer" "$owner" "$read_only"; policy 'issuer: https://issuer.example.com' '' "$read_only")"
expect 1 'is not valid YAML' 'invalid YAML' 'issuer: [unclosed'
# The broker decodes through JSON with case-insensitive field matching, so any
# spelling but the exact one could set a field unseen.
expect 1 'does not define in this exact spelling: App' 'a capitalised App pin' \
  "$(policy "$issuer" "$owner" "$writes" 'App: botantler-1')"
expect 1 'does not define in this exact spelling: Permissions' 'capitalised permissions' \
  "$(policy "$issuer" "$owner" $'Permissions:\n  contents: write' 'app: botantler-2')"
expect 1 'does not define in this exact spelling: ſubject' 'a field spelled with a Unicode case fold' \
  "$(policy "$issuer" "$owner" "$read_only" 'ſubject: repo:other/repo:ref:refs/heads/main')"
expect 1 'permissions must use the canonical lowercase names' 'a capitalised permission name' \
  "$(policy "$issuer" "$owner" $'permissions:\n  Contents: write' 'app: botantler-2')"
expect 1 'permissions must use the canonical lowercase names' 'a capitalised permission value' \
  "$(policy "$issuer" "$owner" $'permissions:\n  contents: Write')"
# Where two YAML readers can disagree about a value, the policy is refused.
expect 1 'uses YAML anchors, aliases, merge keys or duplicate keys' 'a merge key hiding the App' \
  "$(policy "$issuer" "$owner" "$writes" $'app: botantler-1\nbase: &b {app: botantler-2}\n<<: *b')"
expect 1 'uses YAML anchors, aliases, merge keys or duplicate keys' 'an alias' \
  "$(policy "$issuer" "$owner" "$read_only" $'audience: &a sts.example.test\naudience_pattern: *a')"
expect 1 'uses YAML anchors, aliases, merge keys or duplicate keys' 'a duplicate key' \
  "$(policy "$issuer" "$owner" "$writes" $'app: botantler-2\napp: botantler-1')"
expect 1 'is not a mapping' 'a list instead of a policy' $'---\n- issuer: https://token.actions.githubusercontent.com'
expect 1 'must name at least one permission' 'no permissions at all' "$(policy "$issuer" "$owner" '')"
expect 1 'must name at least one permission' 'an empty permission set' "$(policy "$issuer" "$owner" 'permissions: {}')"
expect 1 'must name at least one permission' 'permissions that are not a mapping' "$(policy "$issuer" "$owner" 'permissions: read-all')"


# Privileged permissions: only devantler-tech/.github's own policies, for a
# listed workflow on main, each with exactly its listed set.
# dotgithub <workflow file stem> <permission lines> [extra lines]
dotgithub() {
  printf '%s\n' '---' "$issuer" 'subject: repo:devantler-tech/.github:ref:refs/heads/main' 'claim_pattern:' "$owner" \
    "  job_workflow_ref: devantler-tech/\\.github/\\.github/workflows/$1\\.yaml@refs/heads/main" 'permissions:' "$2" "${3:-}"
}
readonly audit_read=$'  metadata: read\n  administration: read'
repository=devantler-tech/.github expect 0 '' 'a listed audit with administration read' "$(dotgithub governance-audits "$audit_read")"
repository=devantler-tech/.github expect 0 '' 'custom properties admin on botantler-1' \
  "$(dotgithub apply-custom-properties $'  organization_administration: write\n  organization_custom_properties: admin' 'app: botantler-1')"
repository=devantler-tech/.github expect 0 '' 'the custom properties read-back on botantler-1' \
  "$(dotgithub apply-custom-properties $'  metadata: read\n  organization_custom_properties: read' 'app: botantler-1')"
expect 1 'outside the reviewed allowlist' 'a listed grant in another repository' "$(dotgithub governance-audits "$audit_read")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'more than the listed set' \
  "$(dotgithub governance-audits $'  administration: write' 'app: botantler-2')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a listed set plus another privileged permission' \
  "$(dotgithub governance-audits $'  administration: read\n  members: read')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'an unlisted workflow' "$(dotgithub stale-repository-identifier "$audit_read")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'members read for an unlisted grant' \
  "$(dotgithub governance-audits $'  members: read')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a listed workflow on another branch' \
  "$(dotgithub governance-audits "$audit_read" | sed 's|yaml@refs/heads/main|yaml@refs/heads/other|')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'another subject' \
  "$(dotgithub governance-audits "$audit_read" | sed 's|^subject: repo:devantler-tech/.github:ref:refs/heads/main$|subject: repo:devantler-tech/.github:ref:refs/heads/other|')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a subject pattern beside the subject' \
  "$(dotgithub governance-audits "$audit_read" 'subject_pattern: repo:.*')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a workflow pattern widened by an alternative' \
  "$(dotgithub governance-audits "$audit_read" | sed 's|yaml@refs/heads/main|yaml@refs/heads/main\|.*|')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a workflow from another repository' \
  "$(dotgithub governance-audits "$audit_read" | sed 's|devantler-tech/\\.github/\\.github/workflows|devantler-tech/platform/\\.github/workflows|')"
# A listed shared workflow's callers may hold its privileged permission, from
# this repository only, for any devantler-tech main, scoped to the caller, with no App named.
# shared <workflow stem> <permission lines> [extra lines]; ref_suffix overrides the ref.
readonly shared_ref_default='([0-9a-f]{40}|refs/heads/main)'
shared() {
  printf '%s\n' '---' "$issuer" "$any_caller" 'claim_pattern:' "$owner" \
    "  job_workflow_ref: devantler-tech/\\.github/\\.github/workflows/$1\\.yaml@${ref_suffix:-${shared_ref_default}}" \
    'permissions:' "$2" "${3-caller_repository: true}"
}
readonly projects_write='  organization_projects: write'
repository=devantler-tech/.github expect 0 '' 'the to-do scanner caller policy' "$(shared scan-for-todo-comments "$projects_write")"
expect 1 'outside the reviewed allowlist' 'the to-do scanner caller policy in another repository' \
  "$(shared scan-for-todo-comments "$projects_write")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'an unlisted shared workflow' \
  "$(shared template-sync "$projects_write")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'more than the listed set' \
  "$(shared scan-for-todo-comments $'  organization_projects: write\n  organization_administration: write')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'the listed set plus a non-privileged write' \
  "$(shared scan-for-todo-comments $'  organization_projects: write\n  contents: write')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a caller policy pinned to botantler-1' \
  "$(shared scan-for-todo-comments "$projects_write" $'caller_repository: true\napp: botantler-1')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a caller policy pinned to botantler-2' \
  "$(shared scan-for-todo-comments "$projects_write" $'caller_repository: true\napp: botantler-2')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a caller pattern that refuses immutable subjects' \
  "$(shared scan-for-todo-comments "$projects_write" | sed 's#^subject_pattern: .*$#subject_pattern: repo:devantler-tech/[A-Za-z0-9._-]+:ref:refs/heads/main#')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a token for every repository' \
  "$(shared scan-for-todo-comments "$projects_write" '')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a token for a repository list' \
  "$(shared scan-for-todo-comments "$projects_write" $'caller_repository: true\nrepositories:\n  - platform')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'callers on any branch' \
  "$(shared scan-for-todo-comments "$projects_write" | sed 's|:ref:refs/heads/main$|:ref:.*|')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'a subject beside the pattern' \
  "$(shared scan-for-todo-comments "$projects_write" $'caller_repository: true\nsubject: repo:devantler-tech/ksail:ref:refs/heads/main')"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'the workflow at any ref' \
  "$(ref_suffix='.*' shared scan-for-todo-comments "$projects_write")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'the workflow at any commit, merged or not' \
  "$(ref_suffix='[0-9a-f]{40}' shared scan-for-todo-comments "$projects_write")"
repository=devantler-tech/.github expect 1 'outside the reviewed allowlist' 'the workflow widened by an alternative' \
  "$(ref_suffix='([0-9a-f]{40}|refs/heads/main|.*)' shared scan-for-todo-comments "$projects_write")"

# Every policy in a repository is checked, not just the first.
rm -rf "$tmp/repo"
mkdir -p "$tmp/repo/.github/chainguard"
policy "$issuer" "$owner" "$read_only" >"$tmp/repo/.github/chainguard/a.sts.yaml"
policy "$issuer" '  repository_owner_id: "1"' "$read_only" >"$tmp/repo/.github/chainguard/b.sts.yaml"
status=0
(cd "$tmp/repo" && bash "$tmp/check.sh") >"$tmp/out" 2>&1 || status=$?
if [[ "$status" != 1 ]] || ! grep -Fq 'file=.github/chainguard/b.sts.yaml' "$tmp/out" ||
  ! grep -Fq '1 problem(s) in 2 broker trust policies' "$tmp/out"; then
  cat "$tmp/out" >&2
  fail 'a bad policy after a good one must still fail'
fi
cases=$((cases + 1))


# A policy whose identity starts with a dot is still read by the broker, so it is checked.
rm -rf "$tmp/repo"
mkdir -p "$tmp/repo/.github/chainguard"
policy "$issuer" "$owner" "$writes" 'app: devantler-tech-engineering' >"$tmp/repo/.github/chainguard/.unchecked.sts.yaml"
status=0
(cd "$tmp/repo" && bash "$tmp/check.sh") >"$tmp/out" 2>&1 || status=$?
if [[ "$status" != 1 ]] || ! grep -Fq 'file=.github/chainguard/.unchecked.sts.yaml' "$tmp/out"; then
  cat "$tmp/out" >&2
  fail 'a dot-prefixed policy must be checked'
fi
cases=$((cases + 1))

# --- Shared workflow pins must be commits on devantler-tech/.github main --------
yq '.jobs.check.steps[] | select(.name == "🔗 Check shared workflow pins are merged") | .run' "$workflow" >"$tmp/pins.sh"
[[ -s "$tmp/pins.sh" ]] || fail 'the pin check step has no script'
[[ "$(yq '.jobs.check.steps[] | select(.name == "🔗 Check shared workflow pins are merged") | .env.GH_TOKEN' "$workflow")" == '${{ github.token }}' ]] ||
  fail 'the pin check reads the public repository with the job token only'
# A stand-in for gh: the commit's first character picks GitHub's answer.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
[[ "$1" == api && "$2" == repos/devantler-tech/.github/compare/main...* && "$3" == --jq && "$4" == .status ]] || { echo "unexpected gh call: $*" >&2; exit 9; }
case "${2##*...}" in
  a*) echo behind ;;
  e*) echo identical ;;
  b*) echo diverged ;;
  f*) echo ahead ;;
  c*) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *) echo 'connection reset by peer' >&2; exit 1 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/gh" "$tmp/bin/sleep"
sha() { printf "$1"'%.0s' {1..40}; }
readonly shared_ref='devantler-tech/.github/.github/workflows/create-release.yaml'
# caller <uses value>: a one-job caller of that reusable workflow.
caller() { printf 'on: push\njobs:\n  call:\n    uses: %s\n' "$1"; }
# pins_expect <exit status> <message substring or empty> <case> <file>=<content>...
pins_expect() {
  local want="$1" message="$2" name="$3" status=0 spec
  shift 3
  rm -rf "$tmp/repo"
  mkdir -p "$tmp/repo/.github/workflows"
  for spec in "$@"; do printf '%s\n' "${spec#*=}" >"$tmp/repo/.github/workflows/${spec%%=*}"; done
  : >"$tmp/gh-calls"
  (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" GH_CALLS="$tmp/gh-calls" bash "$tmp/pins.sh") >"$tmp/out" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || { cat "$tmp/out" >&2; fail "pins: $name: expected exit $want, got $status"; }
  [[ -z "$message" ]] || grep -Fq -- "$message" "$tmp/out" || { cat "$tmp/out" >&2; fail "pins: $name: missing '$message'"; }
  cases=$((cases + 1))
}
pins_expect 0 '0 pinned shared workflow call(s)' 'a repository without workflows'
pins_expect 0 '1 pinned shared workflow call(s)' 'a merged pin beside unpinned and local calls' \
  "release.yaml=$(caller "$shared_ref@$(sha a)")" "ci.yaml=$(caller "$shared_ref@main")" \
  "local.yaml=$(caller ./.github/workflows/x.yaml)" "other.yaml=$(caller "octo/other/.github/workflows/x.yaml@$(sha b)")"
pins_expect 0 '' 'a pin at main itself' "release.yaml=$(caller "$shared_ref@$(sha e)")"
pins_expect 1 'which is not a commit on its main branch (diverged)' 'an unmerged or impostor commit' \
  "release.yaml=$(caller "$shared_ref@$(sha b)")"
pins_expect 1 'which is not a commit on its main branch (ahead)' 'a commit ahead of main' \
  "release.yaml=$(caller "$shared_ref@$(sha f)")"
pins_expect 1 'which is not a commit on its main branch (missing)' 'a commit GitHub does not know' \
  "release.yaml=$(caller "$shared_ref@$(sha c)")"
pins_expect 1 'not a commit on its main branch' 'a pin in a .yml file' "release.yml=$(caller "$shared_ref@$(sha b)")"
pins_expect 1 'not a commit on its main branch' 'a pin in a dot-prefixed workflow' ".release.yaml=$(caller "$shared_ref@$(sha b)")"
pins_expect 1 'not a commit on its main branch' 'a pin hidden by letter case' \
  "release.yaml=$(caller "Devantler-Tech/.GitHub/.github/workflows/create-release.yaml@$(sha B)")"
pins_expect 1 'not a commit on its main branch' 'a pin hidden by a YAML escape' \
  "release.yaml=$(caller '"devantler-tech/\x2egithub/.github/workflows/create-release.yaml@'"$(sha b)"'"')"
pins_expect 1 '1 shared workflow pin(s)' 'a bad pin after a good one' \
  "a.yaml=$(caller "$shared_ref@$(sha a)")" "b.yaml=$(caller "$shared_ref@$(sha b)")"
pins_expect 2 'could not check whether' 'GitHub unreachable after retries' "release.yaml=$(caller "$shared_ref@$(sha d)")"
[[ "$(wc -l <"$tmp/gh-calls")" -eq 3 ]] || fail 'pins: an unreachable GitHub is retried exactly three times'
pins_expect 2 'is not valid YAML' 'a workflow that cannot be read' 'broken.yaml=jobs: [unclosed'
pins_expect 0 '2 pinned shared workflow call(s)' 'the same commit pinned twice' \
  "a.yaml=$(caller "$shared_ref@$(sha a)")" "b.yaml=$(caller "$shared_ref@$(sha a)")"
[[ "$(wc -l <"$tmp/gh-calls")" -eq 1 ]] || fail 'pins: one commit is looked up once'

printf 'test-check-github-broker-policies: %d cases passed\n' "$cases"
