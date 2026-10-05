#!/usr/bin/env bash
# Only modifications to existing deployment files and tests exercised by the
# unconditional validate-manifests job may omit unrelated catalogue smoke jobs.
# Unknown evidence selects the complete catalogue.
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1

full() { printf 'catalogue=true\n'; exit 0; }
[[ $# == 2 ]] || full
base="$1"
head="$2"
[[ "${base}" =~ ^[0-9a-f]{40}$ && "${head}" =~ ^[0-9a-f]{40}$ ]] || full
[[ "${base}" != "${head}" ]] || full
[[ "$(git cat-file -t "${base}" 2>/dev/null)" == commit ]] || full
[[ "$(git cat-file -t "${head}" 2>/dev/null)" == commit ]] || full
ancestor="$(git merge-base --all "${base}" "${head}" 2>/dev/null)" || full
# Multiple merge bases are ambiguous; incomplete shallow history is unknown.
[[ "${ancestor}" =~ ^[0-9a-f]{40}$ ]] || full

diff="$(mktemp)" || full
trap 'rm -f "${diff}"' EXIT
if ! git diff --name-status -z --no-renames --no-ext-diff --no-textconv \
  "${ancestor}" "${head}" -- >"${diff}" 2>/dev/null; then
  full
fi
size="$(wc -c <"${diff}")" || full
[[ "${size}" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || full
(( size > 0 && size <= 1048576 )) || full
last="$(tail -c 1 "${diff}" | od -An -tx1)" || full
[[ "${last//[[:space:]]/}" == 00 ]] || full

reviewed_test() {
  case "$1" in
    tests/admin-team-policy.sh|tests/repository-admin-teams.sh|tests/repository-admin-audit-boundary.sh|\
    tests/governance-audit-aborts.sh|tests/governance-audit-admission.sh|tests/governance-audits-boundary.sh|\
    tests/governance-audit-runner.sh|tests/governance-audit-report.sh|tests/organization-settings.sh|\
    tests/organization-settings-boundary.sh|tests/declarative-coverage.sh|tests/declarative-coverage-fail-closed.sh|\
    tests/repository-update-policy.sh|tests/release-contract.sh|tests/deploy-deletions.sh|\
    tests/world-at-ruin-regression-ruleset.sh|tests/platform-merge-queue-ruleset.sh|tests/ci-aggregate-ruleset.sh|\
    tests/deploy-guards-ruleset.sh|tests/signing-rule-retirement.sh|tests/workflow-execution-inventory.sh|\
    tests/workflow-execution-actors.sh|tests/workflow-execution-policies.sh|tests/apply-workflow-execution-policies.sh|\
    tests/repository-drift.sh|tests/repository-coverage.sh) return 0 ;;
    *) return 1 ;;
  esac
}

count=0
while IFS= read -r -d '' status; do
  # Additions, deletions, renames and type changes retain complete coverage.
  [[ "${status}" == M ]] || full
  IFS= read -r -d '' path || full
  [[ "${path}" =~ ^[a-zA-Z0-9._/-]+$ ]] || full
  case "/${path}/" in *'//'*|*'/../'*|*'/./'*) full ;; esac
  case "${path}" in
    deploy/*) ;;
    *) reviewed_test "${path}" || full ;;
  esac
  # An existing symlink can change with status M. Both sides must be regular
  # blobs; deployment validation must not redirect into another source surface.
  for revision in "${ancestor}" "${head}"; do
    entry="$(git ls-tree "${revision}" -- "${path}" 2>/dev/null)" || full
    [[ "${entry}" =~ ^100(644|755)[[:space:]]blob[[:space:]][0-9a-f]{40}[[:space:]] ]] || full
  done
  count=$((count + 1))
done <"${diff}"
(( count > 0 )) || full
printf 'catalogue=false\n'
