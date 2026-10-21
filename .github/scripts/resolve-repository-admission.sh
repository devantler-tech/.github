#!/usr/bin/env bash
# Resolve only GitHub-supplied identities and a reviewed base's closed budget.
set -euo pipefail
umask 077

# Refuse incomplete input without emitting a successful admission decision.
fail() {
  echo "::error::repository admission: $*" >&2
  exit 2
}
for required in GITHUB_OUTPUT TARGET_REPOSITORY EVENT_NAME WORKFLOW_REF WORKFLOW_SHA CANDIDATE_SHA; do
  [[ -n "${!required:-}" ]] || fail "missing context field $required"
done
[[ "$TARGET_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || fail 'invalid repository identity'
[[ "${TARGET_REPOSITORY#*/}" != . && "${TARGET_REPOSITORY#*/}" != .. ]] || fail 'invalid repository name'
[[ "$WORKFLOW_SHA" =~ ^[0-9a-f]{40}$ && "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail 'source and candidate must be immutable commits'
case "$EVENT_NAME" in
pull_request | merge_group) ;;
*) fail 'unsupported event' ;;
esac

source_repository=devantler-tech/.github
source_path="$source_repository/.github/workflows/repository-pr-admission.yaml"
source_only=false
if [[ "$TARGET_REPOSITORY" == "$source_repository" ]]; then
  if [[ "$EVENT_NAME" == pull_request && "$WORKFLOW_REF" == "$source_path@refs/pull/"* ]]; then
    suffix=${WORKFLOW_REF#"$source_path@refs/pull/"}
    [[ "$suffix" =~ ^[1-9][0-9]*/merge$ ]] && source_only=true
  elif [[ "$EVENT_NAME" == merge_group && "$WORKFLOW_REF" == "$source_path@refs/heads/gh-readonly-queue/"* ]]; then
    suffix=${WORKFLOW_REF#"$source_path@refs/heads/gh-readonly-queue/"}
    [[ "$suffix" =~ ^[A-Za-z0-9_./-]+$ ]] && source_only=true
  fi
fi

# Ordinary candidate-owned events in this source repository are not the required
# invocation. They must not load a candidate action or weaken the existing gate.
# The ruleset-injected invocation has the canonical reviewed-main workflow ref.
if [[ "$source_only" == true ]]; then
  printf 'run=false\ntrusted-sha=%s\ntimeout-minutes=10\n' "$WORKFLOW_SHA" >>"$GITHUB_OUTPUT"
  exit 0
fi
[[ "$WORKFLOW_REF" == "$source_path@refs/heads/main" ]] || fail 'workflow origin is not reviewed shared main'
[[ -n "${DEFAULT_BRANCH:-}" ]] || fail 'GitHub supplied no product default branch'
case "$EVENT_NAME" in
pull_request)
  [[ "${PULL_REQUEST_BASE_REF:-}" == "$DEFAULT_BRANCH" ]] || fail 'PR base is not the product default branch'
  trusted_sha=${PULL_REQUEST_BASE_SHA:-}
  ;;
merge_group)
  [[ "${MERGE_GROUP_BASE_REF:-}" == "refs/heads/$DEFAULT_BRANCH" ]] || fail 'merge-group base is not the product default branch'
  trusted_sha=${MERGE_GROUP_BASE_SHA:-}
  ;;
esac
[[ "$trusted_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'GitHub supplied no immutable trusted base'
[[ -n "${GH_TOKEN:-}" ]] || fail 'read-only API authorization is missing'

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
gh api "repos/$TARGET_REPOSITORY/contents/.github/pr-admission.json?ref=$trusted_sha" \
  >"$scratch/response.json" 2>"$scratch/api-error" || fail 'reviewed contract could not be read'
jq -se '
  length == 1 and (.[0] |
    .type == "file" and .encoding == "base64" and
    (.content | type == "string" and length > 0 and length <= 8192))
' "$scratch/response.json" >/dev/null || fail 'contract response is incomplete or unsupported'
# GitHub's Contents API wraps base64 with line feeds. Normalize only that
# transport formatting; malformed bytes and decoded contracts still fail closed.
jq -er '.content | gsub("\n"; "") | @base64d' "$scratch/response.json" >"$scratch/contract.json" || fail 'contract encoding is invalid'
[[ "$(wc -c <"$scratch/contract.json" | tr -d ' ')" -le 4096 ]] || fail 'contract is too large'
# Parsing must not silently accept a repeated decoded JSON key.
jq --stream -se '
  [.[] | select(length == 2) | .[0]] as $paths |
  ($paths | length) == ($paths | unique | length)
' "$scratch/contract.json" >/dev/null || fail 'contract has repeated or malformed fields'
jq -se '
  length == 1 and (.[0] |
    type == "object" and (keys | sort) == ["timeout-minutes","version"] and
    .version == 1 and
    (."timeout-minutes" | type == "number" and . == floor and . >= 1 and . <= 90))
' "$scratch/contract.json" >/dev/null || fail 'contract schema or execution budget is invalid'
budget=$(jq -r '."timeout-minutes"' "$scratch/contract.json")
printf 'run=true\ntrusted-sha=%s\ntimeout-minutes=%s\n' "$trusted_sha" "$budget" >>"$GITHUB_OUTPUT"
