#!/usr/bin/env bash
# Execute the shipped input resolver and credential guard, and bind the token all
# the way through the same-commit composite. No real credential or API is used.
set -euo pipefail

workflow="${1:-.github/workflows/dependency-review.yaml}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check_workflow() {
  local file="$1" cfg guard mode token expected status
  yq -o=json '.' "$file" >"$tmp/workflow.json" || return 1
  # shellcheck disable=SC2016 # These are GitHub expressions, compared literally.
  jq -e '
    .permissions == {} and
    ([.jobs[].permissions == {"contents":"read"}] | all) and
    .on.workflow_call.secrets["repo-token"].required == false and
    .on.workflow_call.inputs["comment-summary-in-pr"].default == "never" and
    .on.workflow_call.inputs["warn-only"].default == true and
    (.jobs["dependency-review"].steps as $steps |
      [$steps[] | select(.id == "cfg")] as $cfg |
      [$steps[] | select(.id == "comment-token")] as $guard |
      [$steps[] | select(.uses == "./.devantler-tech-actions/actions/dependency-review")] as $review |
      ($cfg | length) == 1 and ($guard | length) == 1 and ($review | length) == 1 and
      $cfg[0].env.IN_COMMENT_SUMMARY == "${{ inputs.comment-summary-in-pr }}" and
      $cfg[0].env.IN_WARN_ONLY == "${{ inputs.warn-only }}" and
      $guard[0].env.COMMENT_MODE == "${{ steps.cfg.outputs.comment-summary-in-pr }}" and
      $guard[0].env.REVIEW_TOKEN == "${{ secrets.repo-token }}" and
      $guard[0].shell == "bash" and
      ($guard[0] | has("if") or has("continue-on-error") | not) and
      $review[0].with["comment-summary-in-pr"] == "${{ steps.cfg.outputs.comment-summary-in-pr }}" and
      $review[0].with["repo-token"] == "${{ steps.cfg.outputs.comment-summary-in-pr != '\''never'\'' && secrets.repo-token || github.token }}" and
      ([range(0; $steps | length) | select($steps[.].id == "cfg")][0] <
       [range(0; $steps | length) | select($steps[.].id == "comment-token")][0]) and
      ([range(0; $steps | length) | select($steps[.].id == "comment-token")][0] <
       [range(0; $steps | length) | select($steps[.].uses == "./.devantler-tech-actions/actions/dependency-review")][0]) and
      ([$steps[] | select(.with.path == ".devantler-tech-actions") |
        .with.repository == "${{ job.workflow_repository }}" and
        .with.ref == "${{ job.workflow_sha }}" and .with["persist-credentials"] == false] == [true]))
  ' "$tmp/workflow.json" >/dev/null || return 1
  cfg="$(jq -r '.jobs["dependency-review"].steps[] | select(.id == "cfg") | .run' "$tmp/workflow.json")"
  guard="$(jq -r '.jobs["dependency-review"].steps[] | select(.id == "comment-token") | .run' "$tmp/workflow.json")"
  [[ -n "$cfg" && -n "$guard" && "$cfg" != null && "$guard" != null ]] || return 1
  # Both direct events (no inputs) and reusable calls, including boolean false.
  for status in '' true false; do
    for mode in never always on-failure; do
      : >"$tmp/output"
      env -i PATH="$PATH" GITHUB_OUTPUT="$tmp/output" \
        IN_FAIL_ON_SEVERITY=high IN_FAIL_ON_SCOPES=development \
        IN_ALLOW_LICENSES=MIT IN_DENY_LICENSES='' IN_COMMENT_SUMMARY="$mode" \
        IN_WARN_ONLY="$status" bash -euo pipefail -c "$cfg" >"$tmp/cfg.log" 2>&1 || return 1
      if [[ -z "$status" ]]; then
        expected=$'fail-on-severity=critical\nfail-on-scopes=runtime\nallow-licenses=\ndeny-licenses=\ncomment-summary-in-pr=never\nwarn-only=true'
      else
        expected=$'fail-on-severity=high\nfail-on-scopes=development\nallow-licenses=MIT\ndeny-licenses=\ncomment-summary-in-pr='"$mode"$'\nwarn-only='"$status"
      fi
      [[ "$(cat "$tmp/output")" == "$expected" ]] || return 1
    done
  done
  for mode in never always on-failure invalid ''; do
    for token in '' fixture-comment-token; do
      status=0
      env -i PATH="$PATH" COMMENT_MODE="$mode" REVIEW_TOKEN="$token" \
        bash -euo pipefail -c "$guard" >"$tmp/guard.log" 2>&1 || status=$?
      case "$mode" in
      never) [[ "$status" == 0 ]] || return 1 ;;
      always | on-failure)
        if [[ -n "$token" ]]; then
          [[ "$status" == 0 ]] || return 1
        else
          [[ "$status" != 0 ]] || return 1
          grep -Fq 'repo-token with Contents read and Pull requests write' "$tmp/guard.log" || return 1
        fi
        ;;
      *) [[ "$status" != 0 ]] || return 1 ;;
      esac
      # The fixture stands in for a secret: even a rejected request must not print it.
      if grep -Fq fixture-comment-token "$tmp/guard.log"; then return 1; fi
    done
  done
}

check_workflow "$workflow" || fail 'dependency-review comment credential contract or behavior'
yq -o=json '.' "$workflow" >"$tmp/baseline.json"

# The final action must actually receive the chosen credential, at the same ref.
# shellcheck disable=SC2016
yq -o=json '.' actions/dependency-review/action.yaml | jq -e '
  .inputs["repo-token"].default == "${{ github.token }}" and
  ([.runs.steps[] | select(.uses == "actions/dependency-review-action@a1d282b36b6f3519aa1f3fc636f609c47dddb294") |
    .with["repo-token"] == "${{ inputs.repo-token }}"] == [true])' >/dev/null ||
  fail 'the composite must forward repo-token to the pinned upstream action'

yq -o=json '.' .github/workflows/ci.yaml | jq -e '
  .jobs["test-dependency-review-workflow"].permissions == {"contents":"read"} and
  .jobs["test-dependency-review-workflow"].secrets == null' >/dev/null ||
  fail 'the default hosted workflow test must remain credential-free and read-only'

# Regression controls exercise the same validator against deliberate mistakes.
# shellcheck disable=SC2016 # GitHub expressions in jq mutation fixtures.
mutations=(
  'del(.on.workflow_call.secrets)'
  '.on.workflow_call.secrets["repo-token"].required = true'
  '.permissions = {"pull-requests":"write"}'
  '.jobs["dependency-review"].permissions["pull-requests"] = "write"'
  '.jobs.writer = {"if":"false", "permissions":{"pull-requests":"write"}, "steps":[]}'
  '.on.workflow_call.inputs["comment-summary-in-pr"].default = "always"'
  '.on.workflow_call.inputs["warn-only"].default = false'
  'del(.jobs["dependency-review"].steps[] | select(.id == "comment-token"))'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).run = "true"'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).if = "false"'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).["continue-on-error"] = true'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).env.COMMENT_MODE = "${{ inputs.comment-summary-in-pr }}"'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).env.REVIEW_TOKEN = "${{ github.token }}"'
  '(.jobs["dependency-review"].steps[] | select(.id == "comment-token")).run = "echo fixture-comment-token"'
  '(.jobs["dependency-review"].steps[] | select(.id == "cfg")).run = "true"'
  '(.jobs["dependency-review"].steps[] | select(.uses == "./.devantler-tech-actions/actions/dependency-review")).with["repo-token"] = "${{ github.token }}"'
  '(.jobs["dependency-review"].steps[] | select(.uses == "./.devantler-tech-actions/actions/dependency-review")).with["repo-token"] = "${{ secrets.repo-token || github.token }}"'
  '(.jobs["dependency-review"].steps[] | select(.uses == "./.devantler-tech-actions/actions/dependency-review")).with["comment-summary-in-pr"] = "${{ inputs.comment-summary-in-pr }}"'
  '(.jobs["dependency-review"].steps[] | select(.with.path == ".devantler-tech-actions")).with.ref = "main"'
  '.jobs["dependency-review"].steps |= reverse'
)
for mutation in "${mutations[@]}"; do
  jq "$mutation" "$tmp/baseline.json" >"$tmp/mutated.json"
  if check_workflow "$tmp/mutated.json" >/dev/null 2>&1; then
    fail "accepted regression: $mutation"
  fi
done
echo "PASS: dependency-review defaults, comment credential guard, forwarding, and ${#mutations[@]} regression controls"
