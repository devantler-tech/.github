#!/usr/bin/env bash

# An organization-required workflow is compiled in each consumer repository. A job-level
# `uses: ./.github/workflows/...` therefore resolves in the consumer, not in this source
# repository, and GitHub rejects the workflow before it creates a single job.

set -euo pipefail

workflow="${1:-.github/workflows/validate-go-project.yaml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail "workflow not found: $workflow"

consumer_relative_calls="$(
  yq -r '[.jobs[] | (.uses // "") | select(test("^\\./\\.github/workflows/"))] | .[]' \
    "$workflow"
)"

[[ -z "$consumer_relative_calls" ]] ||
  fail "required workflow contains consumer-relative reusable-workflow calls: ${consumer_relative_calls//$'\n'/, }"

# The three signed-fixes callers must name ONE reference: this source repository, the signed-fixes
# workflow path, and a full commit. A branch or a tag is mutable, another repository or path is a
# different workflow, and callers that disagree run different code in one validation.
#
# What is reviewed is the CONTENT of that workflow, so the content is what this test pins: the Git
# blob id of the reviewed `apply-signed-fixes.yaml`. The referenced commit must carry exactly that
# file. The workflow is self-contained (commit-pinned actions and inline scripts only), so its blob
# id covers everything a caller runs. A release that leaves the workflow untouched therefore passes
# with no edit here, and a release that changes it fails until the new content has been reviewed and
# its blob id recorded below (#484: naming the commit instead made every release bump fail until
# someone copied the commit Dependabot had already chosen, which reviewed nothing).
signed_fixes_path='.github/workflows/apply-signed-fixes.yaml'
reviewed_blob='ccbcbabb46c1c5ae40066d05880ff29c50263f25'
source_remote='https://github.com/devantler-tech/.github.git'
# Each reference is read JSON-encoded: command substitution drops trailing newlines, so a plain
# read would accept text after the commit.
ref_pattern="^\"(devantler-tech/\\.github/${signed_fixes_path//./\\.}@[0-9a-f]{40})\"\$"

common_ref=''
for job in apply-tidy-fixes apply-golangci-lint-fixes apply-fixes; do
  encoded_ref="$(yq -o=json -I=0 ".jobs.\"${job}\".uses // \"\"" "$workflow")"
  [[ "$encoded_ref" =~ $ref_pattern ]] ||
    fail "${job} must call the signed-fixes workflow in the source repository at a full commit, got ${encoded_ref}"
  actual_ref="${BASH_REMATCH[1]}"
  [[ -z "$common_ref" || "$actual_ref" == "$common_ref" ]] ||
    fail "${job} calls '${actual_ref}' but an earlier signed-fixes caller calls '${common_ref}'; all three must name one reference"
  common_ref="$actual_ref"
done
[[ -n "$common_ref" ]] || fail "no signed-fixes caller was examined"
pinned_commit="${common_ref##*@}"


# A shallow checkout does not hold the referenced commit, and fetching it into the checkout would
# turn a full clone shallow and add a partial-clone remote to its configuration. So a commit that
# is absent is fetched into a throwaway repository and read there; this test never writes to the
# repository it runs in. Only the commit's trees are fetched: the blob id is recorded in the tree,
# so the file itself is never downloaded. The fetch is bounded twice: Git aborts a transfer that
# stalls for a minute, and where `timeout` exists (every CI runner; not stock macOS) the whole
# command has a two-minute deadline. Either way a hung network fails this test instead of holding
# its job until the runner's own limit.
object_store=()
if ! git cat-file -e "${pinned_commit}^{commit}" 2>/dev/null; then
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  git init --quiet --bare "$scratch/source.git"
  object_store=(--git-dir "$scratch/source.git")
  bounded=()
  if command -v timeout >/dev/null 2>&1; then
    bounded=(timeout 2m)
  fi
  ${bounded[@]+"${bounded[@]}"} git "${object_store[@]}" \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --quiet --no-tags --depth=1 --filter=blob:none "$source_remote" "$pinned_commit" 2>/dev/null ||
    fail "cannot read signed-fixes commit ${pinned_commit} from ${source_remote}; the reference stays unverified"
fi
read_object() {
  git ${object_store[@]+"${object_store[@]}"} "$@"
}
read_object cat-file -e "${pinned_commit}^{commit}" 2>/dev/null ||
  fail "signed-fixes reference ${pinned_commit} is not a commit"

actual_blob="$(read_object rev-parse --verify --quiet "${pinned_commit}:${signed_fixes_path}" || true)"
[[ -n "$actual_blob" ]] ||
  fail "commit ${pinned_commit} has no ${signed_fixes_path}"
[[ "$actual_blob" == "$reviewed_blob" ]] ||
  fail "commit ${pinned_commit} carries ${signed_fixes_path} as blob ${actual_blob}, but the reviewed content is blob ${reviewed_blob}; review the changed workflow, then record its blob id in this test"

echo "PASS: required workflow calls signed fixes through one immutable source-repository reference whose content is the reviewed workflow"
