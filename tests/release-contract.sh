#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-release-contract.sh"

fail() {
  echo "release-contract test: $*" >&2
  exit 1
}

run_validator() {
  local title="$1"
  shift
  printf '%s\0' "$@" | bash "$validator" "$title"
}

expect_success() {
  local title="$1"
  shift
  run_validator "$title" "$@" >/dev/null 2>&1 ||
    fail "expected success for '$title' with paths: $*"
}

expect_failure() {
  local title="$1"
  shift
  if run_validator "$title" "$@" >/dev/null 2>&1; then
    fail "expected failure for '$title' with paths: $*"
  fi
}

# A behavior-changing deploy edit must not disappear behind a no-bump squash
# title. This reproduces the v1.21.4 -> main publication gap from issue #130.
expect_failure \
  'refactor(deploy): rename gitops-tenant-template to platform-tenant-template' \
  deploy/team-repositories/grant-admins-on-platform-tenant-template.yaml

expect_failure \
  'docs(deploy): explain the platform tenant rename' \
  deploy/team-repositories/grant-admins-on-platform-tenant-template.yaml

expect_failure \
  'refactor(deploy): rename a path containing a newline' \
  $'deploy/team-repositories/grant-admins-on-platform\ntenant-template.yaml'

# Every title shape semantic-release maps to a release remains valid.
expect_success \
  'fix(deploy): publish the platform tenant rename' \
  deploy/team-repositories/grant-admins-on-platform-tenant-template.yaml
expect_success \
  'feat(deploy): add a repository policy' \
  deploy/repositories/platform.yaml
expect_success \
  'perf(deploy): reduce reconciliation payloads' \
  deploy/repositories/platform.yaml
expect_success \
  'revert: restore the previous repository policy' \
  deploy/repositories/platform.yaml
expect_success \
  'refactor(deploy)!: replace repository ownership semantics' \
  deploy/repositories/platform.yaml

# Non-artifact changes keep their normal no-bump Conventional Commit types.
expect_success \
  'refactor(ci): simplify the validation workflow' \
  .github/workflows/ci.yaml

echo "release-contract: OK"
