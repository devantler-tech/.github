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

# run_validator_head <pr_title> <commit_count> <first_subject> <paths...> — the
# head-aware form: the guard is told how many commits the branch carries and what
# the first one says, so it can judge the subject GitHub will actually squash under.
run_validator_head() {
  local title="$1" count="$2" subject="$3"
  shift 3
  printf '%s\0' "$@" | bash "$validator" "$title" "$count" "$subject"
}

expect_success_head() {
  local title="$1" count="$2" subject="$3"
  shift 3
  run_validator_head "$title" "$count" "$subject" "$@" >/dev/null 2>&1 ||
    fail "expected success for title '$title' / ${count} commit(s) / subject '$subject' with paths: $*"
}

expect_failure_head() {
  local title="$1" count="$2" subject="$3"
  shift 3
  if run_validator_head "$title" "$count" "$subject" "$@" >/dev/null 2>&1; then
    fail "expected failure for title '$title' / ${count} commit(s) / subject '$subject' with paths: $*"
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

# --- the subject that ACTUALLY lands ------------------------------------------
# This repository is configured squash_merge_commit_title = COMMIT_OR_PR_TITLE, so
# a SINGLE-commit branch squashes under that commit's subject and the PR title is
# never consulted. Validating the title alone therefore green-lights a deploy/
# change that semantic-release will refuse to release — issue #170, reproduced by
# .github#169: its title was edited to a feat:, its lone commit stayed a chore:,
# the guard passed, and no version was cut, so the archived-repository CR was
# never published.
#
# run_validator_head <pr_title> <commit_count> <first_subject> -- <paths...>

# A single-commit branch is judged on its COMMIT subject, not the PR title.
expect_failure_head \
  'feat: archive the doggy-countdown repository' 1 'chore(github): archive doggy-countdown' \
  deploy/archived-repositories/doggy-countdown.yaml

# ...and a releasing commit subject still passes even when the title is not.
expect_success_head \
  'chore: tidy the archived repository list' 1 'feat(deploy): archive doggy-countdown' \
  deploy/archived-repositories/doggy-countdown.yaml

# A MULTI-commit branch has no single commit subject to inherit, so GitHub falls
# back to the PR title and so does the guard.
expect_success_head \
  'feat: archive the doggy-countdown repository' 3 'chore(github): archive doggy-countdown' \
  deploy/archived-repositories/doggy-countdown.yaml
expect_failure_head \
  'chore(github): archive doggy-countdown' 3 'feat(deploy): archive doggy-countdown' \
  deploy/archived-repositories/doggy-countdown.yaml

# The non-deploy exemption is unchanged whichever subject would land.
expect_success_head \
  'chore(ci): tidy a workflow' 1 'chore(ci): tidy a workflow' \
  .github/workflows/ci.yaml

echo "release-contract: OK"
