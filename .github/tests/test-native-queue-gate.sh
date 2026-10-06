#!/usr/bin/env bash
# A successful matrix result must not hide a missing native queue evaluation.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
ci="${1:-$root/.github/workflows/ci.yaml}"
yq -r '.jobs.ci-required-checks.steps[] | select(.name == "📊 Summarize workflow result") | .run' "$ci" > "$work/gate.sh"
mkdir "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'api repos/devantler-tech/fixture/actions/runs/123/attempts/2/jobs?per_page=100 --paginate --slurp' ]] || exit 99
printf 'read\n' >> "$FIXTURE/reads"
cat "$FIXTURE/response.json"
SH
chmod +x "$work/bin/gh"
cat > "$work/response.json" <<'JSON'
[{"total_count":3,"jobs":[
  {"id":1,"run_id":123,"run_attempt":2,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"[Test] Enable Auto-Merge - Queue Slot 1","status":"completed","conclusion":"success"},
  {"id":3,"run_id":123,"run_attempt":2,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"[Test] Enable Auto-Merge - Queue Slot 3","status":"completed","conclusion":"success"},
  {"id":4,"run_id":123,"run_attempt":2,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Unrelated check","status":"completed","conclusion":"success"}
]}]
JSON
check() {
  local label="$1" selected="$2" needs="$3" expected="$4" reads="$5" rc=0
  rm -f "$work/reads"
  (
    cd "$work"
    export PATH="$work/bin:$PATH" FIXTURE="$work"
    export REPOSITORY=devantler-tech/fixture RUN_ID=123 RUN_ATTEMPT=2 HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    export JOB_RESULTS='success success' CATALOGUE_REQUIRED="${6:-true}" SELECTOR_RESULT="${7:-success}"
    export SELECTED_JOBS="$selected" NEEDS_JSON="$needs"
    bash "$work/gate.sh"
  ) > "$work/output" 2>&1 || rc=$?
  if [[ "$expected" == pass && "$rc" != 0 || "$expected" == fail && "$rc" == 0 ]]; then
    cat "$work/output" >&2
    echo "FAIL: required gate $label expected $expected, got exit $rc" >&2
    exit 1
  fi
  local actual=0
  [[ ! -f "$work/reads" ]] || actual=$(wc -l < "$work/reads" | tr -d ' ')
  [[ "$actual" == "$reads" ]] || { cat "$work/output" >&2; echo "FAIL: $label read native evidence $actual times, expected $reads" >&2; exit 1; }
  echo "PASS: $label"
}
selected='["test-enable-auto-merge-queue","test-other"]'
successful='{"select-ci-tests":{"result":"success"},"test-enable-auto-merge-queue":{"result":"success"},"test-other":{"result":"success"}}'
check 'rejects a successful matrix with missing native queue slot 2' "$selected" "$successful" fail 1
check 'rejects a disconnected successful observer result' "$selected" \
  '{"select-ci-tests":{"result":"success"},"test-enable-auto-merge-queue":{"result":"success"},"test-other":{"result":"success"},"test-enable-auto-merge-queue-results":{"result":"success"}}' fail 1

cp "$root/.github/tests/fixtures/queue-slots.json" "$work/response.json"
check 'full selection accepts complete current-attempt native slots' "$selected" "$successful" pass 1
check 'narrow selection omits the native query when the queue was not scheduled' \
  '["test-other"]' '{"test-other":{"result":"success"},"test-enable-auto-merge-queue":{"result":"skipped"}}' pass 0
check 'selected skipped queue fails before any API read' "$selected" \
  '{"test-other":{"result":"success"},"test-enable-auto-merge-queue":{"result":"skipped"}}' fail 0
check 'missing queue dependency cannot be treated as skipped' '["test-other"]' \
  '{"test-other":{"result":"success"}}' fail 0
check 'unknown queue result fails before any API read' '["test-other"]' \
  '{"test-other":{"result":"success"},"test-enable-auto-merge-queue":{"result":"unknown"}}' fail 0
check 'excluded catalogue event preserves the original no-query skip' '' \
  '{"test-enable-auto-merge-queue":{"result":"skipped"}}' pass 0 false skipped
check 'excluded event rejects manufactured selection' "$selected" "$successful" fail 0 false success
check 'malformed selection fails before any API read' '{' "$successful" fail 0

# Native reruns must recreate every slot, including otherwise unrelated jobs.
jq '.[1].jobs[1].run_attempt = 1' "$root/.github/tests/fixtures/queue-slots.json" > "$work/response.json"
check 'partial rerun cannot reuse an earlier-attempt job' "$selected" "$successful" fail 1
jq '.[0].jobs[0].conclusion = "failure"' "$root/.github/tests/fixtures/queue-slots.json" > "$work/response.json"
check 'successful matrix cannot tolerate a failed native slot' "$selected" "$successful" fail 1

# A step/job-level tolerated error would disconnect the proof from the check.
yq -o=json '.jobs.ci-required-checks' "$ci" | jq -e '
  (."continue-on-error" == null or ."continue-on-error" == false) and
  all(.steps[]; (."continue-on-error" == null or ."continue-on-error" == false))
' > /dev/null || { echo 'FAIL: required gate tolerates a native proof failure' >&2; exit 1; }

# The API reports the PR head, while github.sha is its synthetic merge commit.
# Preserve provider bindings rather than allowing an input to choose the proof.
yq -o=json '.jobs.ci-required-checks.steps[] | select(.name == "📊 Summarize workflow result") | .env' "$ci" | jq -e '
  .GH_HOST == "github.com" and
  .REPOSITORY == "${{ github.repository }}" and
  .RUN_ID == "${{ github.run_id }}" and
  .RUN_ATTEMPT == "${{ github.run_attempt }}" and
  .HEAD_SHA == "${{ github.event.pull_request.head.sha || github.sha }}"
' > /dev/null || { echo 'FAIL: native queue proof lacks exact provider head and attempt bindings' >&2; exit 1; }
