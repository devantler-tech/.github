#!/usr/bin/env bash
# Publication fixtures must run independently and still block the required gate.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json . "${1:-$root/.github/workflows/ci.yaml}" >"$work/ci.json"

# shellcheck disable=SC2016 # Literal GitHub expressions, not Bash interpolation.
cat >"$work/check.jq" <<'JQ'
  .jobs["test-publish-contracts"] as $j |
  ["test-publish-caller-pin", "test-publish-app-signs-by-digest",
   "test-publish-preflight", "test-unpublished-version",
   "test-manifests-recovery", "test-app-recovery",
   "test-unpublished-version-native", "test-app-signed-promotion",
   "test-publish-manifests-promotion"] as $tests |
  ($j != null) and
  ($j.needs == null) and
  ($j.if == "${{ github.event_name != 'merge_group' && !startsWith(github.event.head_commit.message, 'chore(main): release ') }}") and
  ($j.permissions == {"contents":"read"}) and
  ($j."continue-on-error" == null or $j."continue-on-error" == false) and
  ($j.defaults.run.shell == null or $j.defaults.run.shell == "bash") and
  ($j.defaults.run."working-directory" == null or $j.defaults.run."working-directory" == ".") and
  ($j.steps[0].uses | startswith("step-security/harden-runner@")) and
  ($j.steps[1].uses | startswith("actions/checkout@")) and
  ($j.steps[1].with."persist-credentials" == false) and
  ([$j.steps[] | select(.run != null) | .run] ==
    [$tests[] | "bash .github/tests/" + . + ".sh"]) and
  ([$j.steps[] | .if] | all(. == null)) and
  ([$j.steps[] | ."continue-on-error"] | all(. == null or . == false)) and
  ([$j.steps[] | .shell] | all(. == null or . == "bash")) and
  ([$j.steps[] | ."working-directory"] | all(. == null or . == ".")) and
  ([$j.steps[] | select(.uses != null) | .uses] | length == 4) and
  ([$j.steps | to_entries[] | select((.value.uses // "") | startswith("sigstore/cosign-installer@")) | .key][0] as $c |
   [$j.steps | to_entries[] | select((.value.uses // "") | startswith("fluxcd/flux2/action@")) | .key][0] as $f |
   [$j.steps | to_entries[] | select(.value.run == "bash .github/tests/test-unpublished-version-native.sh") | .key][0] as $n |
   $c != null and $f != null and $c < $n and $f < $n) and
  (.jobs["ci-required-checks"].needs | index("test-publish-contracts") != null) and
  ([.jobs["ci-required-checks"].steps[]?.env.JOB_RESULTS // ""] | join("\n") |
    contains("${{ needs.test-publish-contracts.result }}"))
JQ
check() { jq -e -f "$work/check.jq" "$1" >/dev/null; }
if ! check "$work/ci.json"; then
  echo 'FAIL: publication fixtures must run independently with complete blocking coverage' >&2
  exit 1
fi
for mutation in \
  'del(.jobs["test-publish-contracts"].steps[2])' \
  '.jobs["test-publish-contracts"].steps[2].if = "false"' \
  '.jobs["test-publish-contracts"].steps[2]."continue-on-error" = true' \
  '.jobs["test-publish-contracts"].needs = ["select-ci-tests"]' \
  '.jobs["test-publish-contracts"].if = "false"' \
  '.jobs["test-publish-contracts"].permissions.contents = "write"' \
  '.jobs["test-publish-contracts"]."continue-on-error" = true' \
  '.jobs["test-publish-contracts"].defaults.run."working-directory" = "fixture"' \
  '.jobs["test-publish-contracts"].steps[1].with."persist-credentials" = true' \
  '.jobs["test-publish-contracts"].steps |= map(select((.uses // "" | startswith("sigstore/cosign-installer@")) | not))' \
  '.jobs["ci-required-checks"].needs |= map(select(. != "test-publish-contracts"))' \
  '(.jobs["ci-required-checks"].steps[] | select(.env.JOB_RESULTS != null) | .env.JOB_RESULTS) |= gsub("\\$\\{\\{ needs.test-publish-contracts.result \\}\\}"; "")'; do
  jq "$mutation" "$work/ci.json" >"$work/mutated.json"
  if check "$work/mutated.json"; then
    echo "FAIL: accepted disconnected or weakened publication coverage: $mutation" >&2
    exit 1
  fi
done
reducer="$(jq -r '.jobs["ci-required-checks"].steps[] | select(.name == "📊 Summarize workflow result") | .run' "$work/ci.json")"
JOB_RESULTS='success success' CATALOGUE_REQUIRED=true SELECTOR_RESULT=success \
  SELECTED_JOBS='[]' NEEDS_JSON='{}' bash -c "$reducer" >"$work/gate.log" 2>&1
for outcome in failure cancelled; do
  if JOB_RESULTS="success $outcome" CATALOGUE_REQUIRED=true SELECTOR_RESULT=success \
    SELECTED_JOBS='[]' NEEDS_JSON='{}' bash -c "$reducer" >"$work/gate.log" 2>&1; then
    echo "FAIL: the required reducer accepted publication outcome $outcome" >&2
    exit 1
  fi
  grep -F 'at least one job failed or was cancelled' "$work/gate.log" >/dev/null
done
echo 'PASS: independent publication coverage and failure controls'
