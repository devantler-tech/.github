#!/usr/bin/env bash
# Offline, atomic API model. Never fall back to the installed gh executable.
set -euo pipefail
[[ "${1:-}" == api ]] || exit 90
endpoint="${2:-}"
shift 2
printf '%s\n' "$endpoint" >>"$CASE_ROOT/api.log"
zero=0000000000000000000000000000000000000000
case "$endpoint" in
  "repos/$REPO")
    [[ $# == 0 ]] || exit 91
    [[ "$READ_FAILURE" != repository ]] || exit 1
    # GitHub's current opaque repository IDs use the URL-safe alphabet, including '-'.
    jq -n --arg repo "$REPO" '{node_id:"R_fixture-safe",full_name:$repo,private:false}'
    ;;
  graphql)
    [[ "${1:-}" == --input && $# == 2 ]] || exit 91
    input="$2"
    if jq -e '.query | contains("updateRefs(input:")' "$input" >/dev/null; then
      cp "$input" "$CASE_ROOT/ref-request.json"
      jq -e '.variables.input.repositoryId == "R_fixture-safe" and
        (.variables.input.refUpdates | type == "array" and length > 0) and
        all(.variables.input.refUpdates[]; .force == false)' "$input" >/dev/null || exit 96
      operation="$(jq -r '.variables.input.clientMutationId | split("-") | last' "$input")"
      printf '%s\n' "$operation" >>"$CASE_ROOT/operations.log"
      if [[ "$operation" == stage && "$API_MODE" == collision ]]; then
        printf '%s\n' "$OTHER_SHA" >"$CASE_ROOT/staged-head"
      elif [[ "$operation" == promote && "$API_MODE" == concurrent ]]; then
        printf '%s\n' "$OTHER_SHA" >"$CASE_ROOT/remote-head"
      elif [[ "$operation" == promote && "$API_MODE" == stage-concurrent ]]; then
        printf '%s\n' "$OTHER_SHA" >"$CASE_ROOT/staged-head"
      fi
      # Check every precondition before applying any write: updateRefs is atomic.
      jq -c '.variables.input.refUpdates[]' "$input" >"$CASE_ROOT/updates"
      while IFS= read -r update; do
        name="$(jq -r .name <<<"$update")"
        case "$name" in
          "refs/heads/$BRANCH") file="$CASE_ROOT/remote-head" ;;
          "refs/heads/automation/applied-fixes/$STAGING_ID") file="$CASE_ROOT/staged-head" ;;
          *) exit 97 ;;
        esac
        current="$zero"
        [[ ! -f "$file" ]] || current="$(cat "$file")"
        before="$(jq -r '.beforeOid // empty' <<<"$update")"
        if [[ -n "$before" && "$current" != "$before" ]]; then
          printf '{"errors":[{"message":"fixture expected ref mismatch"}]}\n'
          exit 1
        fi
      done <"$CASE_ROOT/updates"
      while IFS= read -r update; do
        name="$(jq -r .name <<<"$update")"
        after="$(jq -r .afterOid <<<"$update")"
        if [[ "$name" == "refs/heads/$BRANCH" ]]; then
          file="$CASE_ROOT/remote-head"
          [[ "$after" == "$(cat "$file")" ]] || printf 'advance\n' >>"$CASE_ROOT/advances.log"
        else
          file="$CASE_ROOT/staged-head"
        fi
        if [[ "$after" == "$zero" ]]; then rm -f "$file"; else printf '%s\n' "$after" >"$file"; fi
      done <"$CASE_ROOT/updates"
      [[ "$operation" != stage || "$API_MODE" != stage-lost ]] || exit 1
      [[ "$operation" != promote || "$API_MODE" != promote-lost ]] || exit 1
      jq '{data:{updateRefs:{clientMutationId:.variables.input.clientMutationId}}}' "$input"
      exit 0
    fi
    cp "$input" "$CASE_ROOT/request.json"
    jq -e --arg repo "$REPO" --arg branch "automation/applied-fixes/$STAGING_ID" --arg head "$BASE_SHA" --arg message "$COMMIT_MESSAGE" '
      .variables.input as $i |
      $i.branch.repositoryNameWithOwner == $repo and
      $i.branch.branchName == $branch and $i.expectedHeadOid == $head and
      $i.message.headline == $message and
      ($i | has("author") or has("committer") or has("signature") | not)
    ' "$input" >/dev/null || exit 92
    [[ "$(cat "$CASE_ROOT/remote-head")" == "$BASE_SHA" ]] || exit 98
    [[ "$(cat "$CASE_ROOT/staged-head")" == "$BASE_SHA" ]] || exit 98
    case "$API_MODE" in
      stale) printf '{"errors":[{"message":"expected head mismatch"}]}\n'; exit 1 ;;
      rejected) printf '{"errors":[{"message":"fixture rejected mutation"}]}\n'; exit 1 ;;
      errors) printf '{"errors":[{"message":"fixture GraphQL error"}]}\n'; exit 0 ;;
    esac
    printf '%s\n' "$CREATED_SHA" >"$CASE_ROOT/staged-head"
    printf 'create\n' >>"$CASE_ROOT/operations.log"
    case "$API_MODE" in
      empty) exit 0 ;;
      lost) exit 1 ;;
      malformed) printf 'not JSON\n'; exit 0 ;;
      missing-oid) printf '{"data":{"createCommitOnBranch":{"commit":{}}}}\n'; exit 0 ;;
      bad-oid) printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"invalid"}}}}\n'; exit 0 ;;
    esac
    jq -n --arg oid "$CREATED_SHA" '{data:{createCommitOnBranch:{commit:{oid:$oid}}}}'
    ;;
  "repos/$REPO/commits/$HEAD_SHA"|"repos/$REPO/commits/$CREATED_SHA")
    [[ $# == 0 ]] || exit 94
    if [[ "$endpoint" == "repos/$REPO/commits/$CREATED_SHA" ]]; then
      [[ "$(cat "$CASE_ROOT/remote-head")" == "$BASE_SHA" ]] || exit 98
      printf 'verify\n' >>"$CASE_ROOT/operations.log"
      [[ "$READ_FAILURE" != verification ]] || exit 1
      cat "$CASE_ROOT/verification.json"
    elif [[ -n "${COMMIT_STEP:-}" ]]; then
      [[ "$READ_FAILURE" != verification ]] || exit 1
      cat "$CASE_ROOT/verification.json"
    else
      [[ "$READ_FAILURE" != head ]] || exit 1
      cat "$CASE_ROOT/head.json"
    fi
    ;;
  *) printf 'Unexpected fixture API endpoint\n' >&2; exit 95 ;;
esac
