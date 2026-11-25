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
  (cd "$tmp/repo" && bash "$tmp/check.sh") >"$tmp/out" 2>&1 || status=$?
  [[ "$status" == "$want" ]] || { cat "$tmp/out" >&2; fail "$name: expected exit $want, got $status"; }
  [[ -z "$message" ]] || grep -Fq -- "$message" "$tmp/out" || { cat "$tmp/out" >&2; fail "$name: missing '$message'"; }
  cases=$((cases + 1))
}

expect 0 '0 broker trust policies' 'a repository without policies' ''
expect 0 '1 broker trust policies admit only reviewed callers' 'a read-only devantler-tech policy without an App pin' \
  "$(policy "$issuer" "$owner" "$read_only")"
expect 0 '' 'a write policy pinned to botantler-2' "$(policy "$issuer" "$owner" "$writes" 'app: botantler-2')"
expect 0 '' 'the shared release workflow pinned to botantler-1' \
  "$(policy "$issuer" "$owner"$'\n'"$release_workflow" "$writes" 'app: botantler-1')"

expect 1 'must pin claim_pattern.repository_owner_id' 'no caller pin' "$(policy "$issuer" '  ref: refs/heads/main' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'another organization' \
  "$(policy "$issuer" '  repository_owner_id: "1"' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'any owner' "$(policy "$issuer" '  repository_owner_id: ".*"' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'an owner pattern wider than the ID' \
  "$(policy "$issuer" '  repository_owner_id: "178524219|1"' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'the owner ID as a number' \
  "$(policy "$issuer" '  repository_owner_id: 178524219' "$read_only")"
expect 1 'must pin claim_pattern.repository_owner_id' 'an unlisted repository ID instead of the owner' \
  "$(policy "$issuer" '  repository_id: "494599576"' "$read_only")"
expect 1 'name the issuer and App exactly' 'an issuer pattern' \
  "$(policy 'issuer_pattern: https://.*' "$owner" "$read_only")"
expect 1 'must accept exactly the GitHub Actions issuer' 'another issuer' \
  "$(policy 'issuer: https://issuer.example.com' "$owner" "$read_only")"
expect 1 'name the issuer and App exactly' 'an App pattern' "$(policy "$issuer" "$owner" "$writes" 'app_pattern: botantler-.*')"
expect 1 'grants write access without an App pin' 'write access without an App pin' "$(policy "$issuer" "$owner" "$writes")"
expect 1 'only the shared release workflow may use it' 'botantler-1 outside the release workflow' \
  "$(policy "$issuer" "$owner" "$writes" 'app: botantler-1')"
expect 0 '' 'the shared release workflow pinned to a full commit, on botantler-1' \
  "$(policy "$issuer" "$owner"$'\n''  job_workflow_ref: devantler-tech/\.github/\.github/workflows/create-release\.yaml@[0-9a-f]{40}' "$writes" 'app: botantler-1')"
expect 1 'only the shared release workflow may use it' 'a release pattern widened by an alternative' \
  "$(policy "$issuer" "$owner"$'\n''  job_workflow_ref: devantler-tech/\.github/\.github/workflows/create-release\.yaml@.*|.*' "$writes" 'app: botantler-1')"
expect 1 'only the shared release workflow may use it' 'a release pattern on any ref' \
  "$(policy "$issuer" "$owner"$'\n''  job_workflow_ref: devantler-tech/\.github/\.github/workflows/create-release\.yaml@.*' "$writes" 'app: botantler-1')"
expect 1 'only the shared release workflow may use it' 'botantler-1 for a lookalike workflow' \
  "$(policy "$issuer" "$owner"$'\n''  job_workflow_ref: devantler-tech/\.github/\.github/workflows/create-release-x\.yaml@main' "$writes" 'app: botantler-1')"
expect 1 'pins unknown App' 'an unknown App' "$(policy "$issuer" "$owner" "$writes" 'app: devantler-tech-engineering')"
expect 1 'grants administration' 'repository administration' \
  "$(policy "$issuer" "$owner" $'permissions:\n  administration: read' 'app: botantler-2')"
expect 1 'grants administration' 'organization administration' \
  "$(policy "$issuer" "$owner" $'permissions:\n  organization_administration: write' 'app: botantler-2')"
expect 1 'holds 2 YAML documents' 'a second document' \
  "$(policy "$issuer" "$owner" "$read_only"; policy 'issuer: https://issuer.example.com' '' "$read_only")"
expect 1 'is not valid YAML' 'invalid YAML' 'issuer: [unclosed'

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

printf 'test-check-github-broker-policies: %d cases passed\n' "$cases"
