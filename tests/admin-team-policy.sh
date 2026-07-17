#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
production_render="$(mktemp)"
policy_source="$(mktemp)"
trap 'rm -f "$production_render" "$policy_source"' EXIT

kubectl kustomize "$repo_root/deploy" >"$production_render"

fail() {
  echo "admins-policy test: $*" >&2
  exit 1
}

require_count() {
  local expected="$1" pattern="$2" file="$3" actual
  actual="$(grep -Ec "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected matches for '$pattern', got $actual"
}

require_fixed_count() {
  local expected="$1" value="$2" file="$3" actual
  actual="$(grep -Fxc "$value" "$file" || true)"
  [[ "$actual" == "$expected" ]] ||
    fail "expected $expected exact matches for '$value', got $actual"
}

require_count 1 '^  name: admins$' "$production_render"
require_count 1 '^  name: admins-devantler$' "$production_render"
require_count 22 '^  name: admins-' "$production_render"
require_count 21 '^    permission: admin$' "$production_render"
require_count 22 '^      name: admins$' "$production_render"

grant_files=("$repo_root"/deploy/team-repositories/grant-admins-on-*.yaml)
policy_files=(
  "$repo_root/deploy/teams/admins.yaml"
  "$repo_root/deploy/team-memberships/add-devantler-to-admins.yaml"
  "${grant_files[@]}"
)
[[ "${#grant_files[@]}" == 21 ]] ||
  fail "expected 21 Admins grants, got ${#grant_files[@]}"
[[ "${#policy_files[@]}" == 23 ]] ||
  fail "expected 23 Admins policy files, got ${#policy_files[@]}"
cat "${policy_files[@]}" >"$policy_source"

repositories=(
  .github
  actions
  agent-plugins
  agent-skills
  ascoachingogvaner
  aws
  dotnet-template
  fleet-gitops
  gitops-tenant-template
  go-template
  homebrew-tap
  ksail
  kyverno-policies
  maintenance
  monorepo
  platform
  platform-template
  provider-upjet-unifi
  unifi
  wedding-app
  world-at-ruin
)

for repository in "${repositories[@]}"; do
  require_fixed_count 1 "    repository: ${repository}" "$policy_source"
done

require_count 0 '^    repository: reusable-workflows$' "$policy_source"

if grep -Eq '^[[:space:]]*managementPolicies:.*Delete|crossplane.io/external-name' \
  "${policy_files[@]}"; then
  fail "net-new Admins resources must not claim Delete or an external name"
fi

require_count 1 '^    createDefaultMaintainer: false$' "$production_render"
require_count 1 '^    privacy: secret$' "$production_render"

for maintainers_grant in "$repo_root"/deploy/team-repositories/grant-maintainers-on-*.yaml; do
  grep -Eq '^    permission: maintain$' "$maintainers_grant" ||
    fail "existing Maintainers permission changed in $maintainers_grant"
done
