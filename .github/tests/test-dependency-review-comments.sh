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
  ([.runs.steps[] | select(.id == "review")] as $review |
    ($review | length) == 1 and
    ($review[0].uses | test("^actions/dependency-review-action@[0-9a-f]{40}$")) and
    $review[0].with["repo-token"] == "${{ inputs.repo-token }}") and
  ([.runs.steps[] | select((.uses // "") | startswith("actions/dependency-review-action@"))] | length) == 1' >/dev/null ||
  fail 'the composite must forward repo-token to the pinned upstream action'

# Hosted CI runs the action's comment paths against the offline API stand-in. The job
# holds no write permission and no credential, runs every reviewed scenario, and gates
# the required check. The stand-in, the preload and the conversation check have their
# own behaviour test in test-dependency-review-offline.sh.
ci="${2:-.github/workflows/ci.yaml}"
scenarios=.github/tests/dependency-review-offline/scenarios
yq -o=json '.' "$ci" >"$tmp/ci.json"
jq -n '[inputs | {name: (input_filename | split("/") | last | rtrimstr(".json")), inputs: (.inputs | keys),
    mode: .inputs["comment-summary-in-pr"], comment: .expect.comment, outcome: .expect.outcome}]' \
  "$scenarios"/*.json >"$tmp/scenarios.json"

check_ci() { # <ci.json> [reviewed-scenarios.json]
  # shellcheck disable=SC2016 # These are GitHub expressions, compared literally.
  jq -e --slurpfile scenarios "${2:-$tmp/scenarios.json}" '
    def dependency_review:
      (split("@")[0] // "") | split("/") | reduce .[] as $part ([];
        if $part == "" or $part == "." then .
        elif $part == ".." then .[0:-1] else . + [$part] end) |
      last == "dependency-review";
    def position($id): [range(0; length) as $i | select(.[$i].id == $id) | $i];
    "${{ github.event_name != '\''merge_group'\'' && !startsWith(github.event.head_commit.message, '\''chore(main): release '\'') }}" as $condition |
    . as $workflow |
    .jobs["test-dependency-review-comments"] as $job |
    $scenarios[0] as $reviewed |
    if .jobs["test-dependency-review-workflow"].permissions != {"contents":"read"} or
      .jobs["test-dependency-review-workflow"].secrets != null
    then error("the reusable workflow test must stay read-only and secret-free")
    elif ($job | type) != "object"
    then error("the offline comment job is missing")
    elif $job.permissions != {"contents":"read"}
    then error("the offline comment job must have only contents-read permission")
    elif ([.env // {}, $job] | tostring |
      test("\\bsecrets\\b|github\\.token|GH_TOKEN|GITHUB_TOKEN|private-key"; "i"))
    then error("the offline comment job must not receive a credential")
    elif ([$job.steps[] | select((.uses // "") | startswith("actions/checkout@"))] |
      length == 0 or any(.with["persist-credentials"] != false))
    then error("the offline comment checkout must disable persisted credentials")
    elif $job.if != $condition or ($job | has("needs")) or ($job["continue-on-error"] // false) != false
    then error("the offline comment job must run and propagate failures")
    elif $job.strategy != {"fail-fast": false, "matrix": {"scenario": ($reviewed | map(.name) | sort)}}
    then error("the offline comment job must run every reviewed scenario")
    elif ($reviewed | length) == 0 or any($reviewed[]; .inputs != ["comment-summary-in-pr", "warn-only"])
    then error("every scenario must state exactly the inputs the job passes")
    elif ((["always", "on-failure", "never"] - ($reviewed | map(.mode))) +
      (["created", "updated", "rejected", "none"] - ($reviewed | map(.comment))) +
      (["success", "failure"] - ($reviewed | map(.outcome))) | length) != 0
    then error("the reviewed scenarios must cover every comment mode, result and outcome")
    elif ($job.steps | (position("offline") + position("review") + position("verify")) as $order |
      ($order | length) != 3 or $order != ($order | sort) or $order != ($order | unique))
    then error("the stand-in must start before the action and be verified after it")
    elif ($job.steps[] | select(.id == "offline") |
      .env != {"SCENARIO": "${{ matrix.scenario }}"} or
      .run != "bash .github/tests/dependency-review-offline.sh start \"$SCENARIO\"" or
      has("if") or (.["continue-on-error"] // false) != false)
    then error("the stand-in must start for the matrix scenario")
    elif ($job.steps[] | select(.id == "review") |
      .uses != "./actions/dependency-review" or has("if") or
      .with != {
        "comment-summary-in-pr": "${{ steps.offline.outputs.comment-summary-in-pr }}",
        "warn-only": "${{ steps.offline.outputs.warn-only }}",
        "repo-token": "offline-fixture-token"} or
      .env != {
        "NODE_OPTIONS": "--require=${{ github.workspace }}/.github/tests/fixtures/offline-github-env.cjs",
        "OFFLINE_GITHUB_API_URL": "${{ steps.offline.outputs.api-url }}",
        "OFFLINE_GITHUB_EVENT_NAME": "pull_request",
        "OFFLINE_GITHUB_EVENT_PATH": "${{ github.workspace }}/.github/tests/dependency-review-offline/event.json",
        "OFFLINE_GITHUB_REPOSITORY": "offline/fixture",
        "OFFLINE_BLOCKED_HOSTS_FILE": "${{ steps.offline.outputs.blocked-hosts-file }}"})
    then error("the action must run through the composite against the stand-in with the fixture token")
    elif ($job.steps[] | select(.id == "verify") |
      .env != {
        "SCENARIO": "${{ matrix.scenario }}",
        "REVIEW_OUTCOME": "${{ steps.review.outcome }}",
        "COMMENT_CONTENT": "${{ steps.review.outputs.comment-content }}"} or
      .run != "bash .github/tests/dependency-review-offline.sh verify \"$SCENARIO\"" or
      has("if") or (.["continue-on-error"] // false) != false)
    then error("the recorded conversation must be verified and propagate failures")
    elif [.jobs | to_entries[] | select(.key != "test-dependency-review-comments") | .value as $other |
      $other.steps[]? | select((.uses // "") | dependency_review) |
      select($other.permissions != {"contents":"read"} or
        ((.with // {}) | has("repo-token") or ((.["comment-summary-in-pr"] // "never") != "never")))] | length > 0
    then error("live comment-enabled dependency-review invocation in catalogue CI")
    elif (.jobs["ci-required-checks"].needs | index("test-dependency-review-comments")) == null
    then error("the offline comment job must gate required CI")
    elif any(.jobs["ci-required-checks"].steps[];
      (.env.JOB_RESULTS // "" | contains("needs.test-dependency-review-comments.result")) and
      (.run // "" | contains("$JOB_RESULTS"))) | not
    then error("required CI must evaluate the offline comment result")
    else true end
  ' "$1"
}

check_ci "$tmp/ci.json" >/dev/null || fail 'hosted CI must exercise the comment paths offline, read-only and required'

# Mutate the real CI definition; each unsafe boundary must fail for its own reason.
ci_controls=0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$tmp/ci.json" >"$tmp/ci-mutated.json"
  if check_ci "$tmp/ci-mutated.json" >"$tmp/ci-result" 2>&1; then
    fail "accepted CI regression: $label"
  fi
  grep -qF "$diagnostic" "$tmp/ci-result" || {
    cat "$tmp/ci-result" >&2
    fail "CI regression rejected for the wrong reason: $label"
  }
  ci_controls=$((ci_controls + 1))
done <<'CASES'
restored pull-request write	.jobs["test-dependency-review-comments"].permissions["pull-requests"]="write"	only contents-read permission
restored issue write	.jobs["test-dependency-review-comments"].permissions.issues="write"	only contents-read permission
dropped permission block	del(.jobs["test-dependency-review-comments"].permissions)	only contents-read permission
job token as the action token	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).with["repo-token"]="${{ github.token }}"	must not receive a credential
secret as the action token	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).with["repo-token"]="${{ secrets.APP_PRIVATE_KEY }}"	must not receive a credential
job secret	.jobs["test-dependency-review-comments"].env.EXTRA="${{ secrets[\"TOKEN\"] }}"	must not receive a credential
workflow secret	.env.EXTRA="${{ secrets.TOKEN }}"	must not receive a credential
readback token	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify")).env.GH_TOKEN="${{ github.token }}"	must not receive a credential
persisted checkout	.jobs["test-dependency-review-comments"].steps |= map(if (.uses // "" | startswith("actions/checkout@")) then .with["persist-credentials"]=true else . end)	disable persisted credentials
skipped job	.jobs["test-dependency-review-comments"].if="false"	must run and propagate failures
trusted-author fence	.jobs["test-dependency-review-comments"].if="${{ github.event.pull_request.user.login == 'devantler' }}"	must run and propagate failures
tolerated job failure	.jobs["test-dependency-review-comments"]["continue-on-error"]=true	must run and propagate failures
job prerequisite	.jobs["test-dependency-review-comments"].needs=["lint-ci-coverage-parity"]	must run and propagate failures
dropped scenario	.jobs["test-dependency-review-comments"].strategy.matrix.scenario |= map(select(. != "comment-updated"))	run every reviewed scenario
unreviewed scenario	.jobs["test-dependency-review-comments"].strategy.matrix.scenario += ["unreviewed"]	run every reviewed scenario
excluded scenario	.jobs["test-dependency-review-comments"].strategy.matrix.exclude=[{"scenario":"comment-created"}]	run every reviewed scenario
fail-fast matrix	.jobs["test-dependency-review-comments"].strategy["fail-fast"]=true	run every reviewed scenario
missing stand-in	.jobs["test-dependency-review-comments"].steps |= map(select(.id != "offline"))	start before the action
missing verification	.jobs["test-dependency-review-comments"].steps |= map(select(.id != "verify"))	start before the action
verification before the action	.jobs["test-dependency-review-comments"].steps |= (map(select(.id != "verify")) as $rest | [.[] | select(.id == "verify")] as $verify | $rest[0:2] + $verify + $rest[2:])	start before the action
duplicated action run	.jobs["test-dependency-review-comments"].steps |= (. + [.[] | select(.id == "review")])	start before the action
stand-in for a fixed scenario	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "offline")).run="bash .github/tests/dependency-review-offline.sh start comment-never"	start for the matrix scenario
conditional stand-in	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "offline")).if="false"	start for the matrix scenario
remote action reference	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).uses="devantler-tech/.github/actions/dependency-review@main"	through the composite against the stand-in
missing preload	del((.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).env.NODE_OPTIONS)	through the composite against the stand-in
live API address	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).env.OFFLINE_GITHUB_API_URL="https://api.github.com"	through the composite against the stand-in
live repository	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).env.OFFLINE_GITHUB_REPOSITORY="${{ github.repository }}"	through the composite against the stand-in
live event	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).env.OFFLINE_GITHUB_EVENT_PATH="${{ github.event_path }}"	through the composite against the stand-in
fixed comment mode	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).with["comment-summary-in-pr"]="never"	through the composite against the stand-in
live token literal	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).with["repo-token"]="live-token"	through the composite against the stand-in
conditional action	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "review")).if="false"	through the composite against the stand-in
assumed outcome	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify")).env.REVIEW_OUTCOME="success"	verified and propagate failures
assumed report	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify")).env.COMMENT_CONTENT="report"	verified and propagate failures
verification of a fixed scenario	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify")).run="bash .github/tests/dependency-review-offline.sh verify comment-never"	verified and propagate failures
tolerated verification failure	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify"))["continue-on-error"]=true	verified and propagate failures
conditional verification	(.jobs["test-dependency-review-comments"].steps[] | select(.id == "verify")).if="${{ success() }}"	verified and propagate failures
live comment job elsewhere	.jobs.unexpected={permissions:{contents:"read","pull-requests":"write"},steps:[{uses:"./actions/dependency-review",with:{"comment-summary-in-pr":"always"}}]}	live comment-enabled dependency-review invocation
live comment mode elsewhere	.jobs.unexpected={permissions:{contents:"read"},steps:[{uses:"./actions/dependency-review/",with:{"comment-summary-in-pr":"on-failure"}}]}	live comment-enabled dependency-review invocation
explicit token elsewhere	.jobs.unexpected={permissions:{contents:"read"},steps:[{uses:"./actions/other/../dependency-review/.",with:{"repo-token":"${{ github.token }}"}}]}	live comment-enabled dependency-review invocation
write permission on the read-only action test	.jobs["test-dependency-review"].permissions["pull-requests"]="write"	live comment-enabled dependency-review invocation
write permission on the workflow test	.jobs["test-dependency-review-workflow"].permissions["pull-requests"]="write"	reusable workflow test must stay read-only
secret on the workflow test	.jobs["test-dependency-review-workflow"].secrets={"repo-token":"${{ github.token }}"}	reusable workflow test must stay read-only
missing required dependency	.jobs["ci-required-checks"].needs |= map(select(. != "test-dependency-review-comments"))	gate required CI
missing required verdict	.jobs["ci-required-checks"].steps |= map(if .env.JOB_RESULTS then .env.JOB_RESULTS |= gsub("needs.test-dependency-review-comments.result"; "needs.other.result") else . end)	evaluate the offline comment result
CASES

# Mutate the reviewed scenario set, with the matrix kept in step: a set that lost a comment
# mode, result or outcome, or a scenario that leaves an action input to its default, is not
# the reviewed coverage.
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$tmp/scenarios.json" >"$tmp/scenarios-mutated.json"
  jq --slurpfile mutated "$tmp/scenarios-mutated.json" \
    '.jobs["test-dependency-review-comments"].strategy.matrix.scenario = ($mutated[0] | map(.name) | sort)' \
    "$tmp/ci.json" >"$tmp/ci-mutated.json"
  if check_ci "$tmp/ci-mutated.json" "$tmp/scenarios-mutated.json" >"$tmp/ci-result" 2>&1; then
    fail "accepted scenario regression: $label"
  fi
  grep -qF "$diagnostic" "$tmp/ci-result" || {
    cat "$tmp/ci-result" >&2
    fail "scenario regression rejected for the wrong reason: $label"
  }
  ci_controls=$((ci_controls + 1))
done <<'CASES'
no scenario with comments always on	map(select(.mode != "always"))	cover every comment mode, result and outcome
no scenario with comments on failure	map(select(.mode != "on-failure"))	cover every comment mode, result and outcome
no scenario with comments off	map(select(.mode != "never"))	cover every comment mode, result and outcome
no created summary	map(select(.comment != "created"))	cover every comment mode, result and outcome
no updated summary	map(select(.comment != "updated"))	cover every comment mode, result and outcome
no rejected summary	map(select(.comment != "rejected"))	cover every comment mode, result and outcome
no withheld summary	map(select(.comment != "none"))	cover every comment mode, result and outcome
no failing review	map(select(.outcome != "failure"))	cover every comment mode, result and outcome
scenario without warn-only	map(if .name == "comment-never" then .inputs = ["comment-summary-in-pr"] else . end)	exactly the inputs the job passes
scenario with an unreviewed input	map(if .name == "comment-never" then .inputs += ["fail-on-severity"] else . end)	exactly the inputs the job passes
no scenario at all	[]	exactly the inputs the job passes
CASES

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
echo "PASS: dependency-review defaults, credential guard, forwarding, offline hosted comment job with $ci_controls CI controls, and ${#mutations[@]} workflow regression controls"
