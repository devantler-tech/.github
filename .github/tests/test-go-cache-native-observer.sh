#!/usr/bin/env bash
# Exercise the real observer with complete and deliberately incomplete API evidence.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
helper="$root/.github/scripts/observe-go-cache.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
prefix='[Test] Validate Go Project - Isolated PostgreSQL / '
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
key="go-mod-v1-Linux-X64-.github/tests/go-postgresql-fixture-$(printf '%064d' 1)"
mkdir "$scratch/logs"
jq -n --arg head "$head" '{id:23,run_attempt:2,head_sha:$head,event:"pull_request",repository:{full_name:"devantler-tech/.github"}}' >"$scratch/run.json"
jq -n --arg prefix "$prefix" --arg head "$head" '
  def step($name): {name:$name,status:"completed",conclusion:"success"};
  ["🔍 Detect Changes","🏗️ Build","🧹 Lint - golangci-lint","🔍 Dead Code Analysis","📦 Tidy","🧪 Test","📊 Code Coverage","🧹 Lint - mega-linter","🛡️ Vulnerability Scan"] |
  to_entries | map(.key as $index | .value as $name |
    {id:(100+$index),run_id:23,run_attempt:2,head_sha:$head,name:($prefix+$name),status:"completed",conclusion:"success",steps:
      (if $name == "🔍 Detect Changes" then []
       elif $name == "🛡️ Vulnerability Scan" then [step("🛡️ Scan for known vulnerabilities")]
       else [step("Restore Go module cache")] +
         (if $name == "🧪 Test" then [{name:"Save Go module cache",status:"completed",conclusion:"skipped"},{name:"Save Go compilation cache",status:"completed",conclusion:"skipped"}]
          elif $name == "📊 Code Coverage" then [{name:"Save Go compilation cache",status:"completed",conclusion:"skipped"}]
          else [] end) end)}) |
  [{total_count:9,jobs:.[0:4]},{total_count:9,jobs:.[4:]}]
' >"$scratch/jobs.json"
printf '[{"total_count":0,"actions_caches":[]}]\n' >"$scratch/caches.json"
for id in 101 102 103 104 105 106 107 108; do
  printf '##[group]Run actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n  key: %s\n##[endgroup]\nCache not found for input keys: %s\n' "$key" "$key" >"$scratch/logs/$id.log"
done
check() { bash "$helper" check "$1" 23 2 "$head" "$key" "$scratch/run.json" "$scratch/jobs.json" "$scratch/caches.json" "$scratch/logs"; }
check pr >"$scratch/out" 2>"$scratch/error" || fail "complete PR evidence must pass: $(cat "$scratch/error")"
grep -q 'PASS: native Go cache policy' "$scratch/out" || fail 'observer did not publish a positive verdict'
cp "$scratch/jobs.json" "$scratch/good-jobs.json"
reject_jobs() {
  jq "$1" "$scratch/good-jobs.json" >"$scratch/jobs.json"
  if check pr >"$scratch/out" 2>"$scratch/error"; then fail "unsafe native evidence accepted: $1"; fi
  [[ ! -s "$scratch/out" ]] || fail 'failure published a positive verdict'
}
reject_jobs '.[1].jobs[1].steps[1].conclusion = "success"'
reject_jobs '.[0].jobs[1].steps[0].conclusion = "skipped"'
reject_jobs '.[1].jobs |= .[1:]'
reject_jobs '.[1].jobs[0] = .[1].jobs[1]'
reject_jobs '.[0].total_count = 10'
reject_jobs '.[1].jobs[0].run_attempt = 1'
reject_jobs '.[1].jobs[0].head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
reject_jobs '.[1].jobs[0].status = "in_progress"'
reject_jobs '.[1].jobs[0].name += " unexpected"'
reject_jobs '.[1].jobs[1].steps |= map(select(.name != "Save Go module cache"))'
reject_restore_with_summary() {
  reject_jobs "$1"
  local summary
  summary="$(sed -n 's/^native-go-cache: restore-evidence-summary=//p' "$scratch/error")"
  [[ -n "$summary" ]] || fail 'rejected restore has no sanitized diagnostic'
  jq -e --argjson id "${3:-101}" --argjson index "${4:-1}" '
    keys == ["fixture_index", "job_id", "restore_steps", "states"] and
    .job_id == $id and .fixture_index == $index and
    (.restore_steps | type == "number" and . >= 0) and
    (.states | length <= 8 and all(.[];
      keys == ["conclusion", "status"] and
      (.status | IN("queued", "in_progress", "completed", "unrecognized")) and
      (.conclusion | IN(null, "success", "failure", "skipped", "cancelled", "timed_out", "action_required", "neutral", "stale", "startup_failure", "unrecognized"))))
  ' <<<"$summary" >/dev/null || fail 'restore diagnostic exposed unapproved evidence'
  jq -e "$2" <<<"$summary" >/dev/null || fail 'restore diagnostic lost the rejected state'
  if grep -q 'private-response-sentinel' "$scratch/error"; then fail 'restore diagnostic disclosed raw evidence'; fi
}
reject_restore_with_summary '.[0].jobs[1].steps = []' \
  '.restore_steps == 0 and .states == []'
for conclusion in skipped failure cancelled; do
  reject_restore_with_summary ".[0].jobs[1].steps[0].conclusion = \"$conclusion\"" \
    ".restore_steps == 1 and .states == [{status:\"completed\",conclusion:\"$conclusion\"}]"
done
reject_restore_with_summary '.[0].jobs[1].steps[0] |= (.status="in_progress" | .conclusion=null)' \
  '.states == [{status:"in_progress",conclusion:null}]'
reject_restore_with_summary '.[0].jobs[1].steps[0] |= (.status="private-response-sentinel" | .conclusion={private:"private-response-sentinel"} | .output="private-response-sentinel")' \
  '.states == [{status:"unrecognized",conclusion:"unrecognized"}]'
# Native run 40115145442 returned successful fixture jobs with empty steps,
# including the scanner whose composite owns its module restore.
reject_restore_with_summary '.[1].jobs[4].steps = []' \
  '.restore_steps == 0 and .states == []' 108 8
reject_restore_with_summary '.[1].jobs[4].steps[0].conclusion = "failure"' \
  '.restore_steps == 1 and .states == [{status:"completed",conclusion:"failure"}]' 108 8
reject_restore_with_summary '.[1].jobs[4].steps[0] |= (.status="private-response-sentinel" | .conclusion="private-response-sentinel")' \
  '.states == [{status:"unrecognized",conclusion:"unrecognized"}]' 108 8
reject_jobs_with_summary() {
  reject_jobs "$1"
  local summary
  summary="$(sed -n 's/^native-go-cache: job-evidence-summary=//p' "$scratch/error")"
  [[ -n "$summary" ]] || fail 'rejected jobs have no sanitized diagnostic'
  jq -e '
    if keys == ["state"] then .state | IN("invalid_shape", "unreadable")
    else keys == ["duplicate_ids", "fetched_jobs", "fixture_bad_id", "fixture_bad_steps", "fixture_invalid", "fixture_jobs", "fixture_missing_names", "fixture_not_completed", "fixture_not_success", "fixture_unexpected_names", "fixture_wrong_attempt", "fixture_wrong_head", "fixture_wrong_run", "pages", "reported_totals", "total_count_variants"] and
      (.reported_totals | length <= 8 and all(.[]; type == "number" and . > 0 and floor == .)) and
      (del(.reported_totals) | all(.[]; type == "number" and . >= 0 and floor == .)) end
  ' <<<"$summary" >/dev/null || fail 'diagnostic exposed unapproved fields or unbounded values'
  jq -e "$2" <<<"$summary" >/dev/null || fail 'diagnostic does not identify the rejected invariant'
}
reject_jobs_with_summary '.[0].total_count = 10' \
  '.pages == 2 and .reported_totals == [9,10] and .fetched_jobs == 9 and .duplicate_ids == 0 and .fixture_jobs == 9'
reject_jobs_with_summary '.[1].jobs |= .[1:]' \
  '.reported_totals == [9] and .fetched_jobs == 8 and .duplicate_ids == 0 and .fixture_jobs == 8'
reject_jobs_with_summary '.[1].jobs[0] = .[1].jobs[1]' \
  '.fetched_jobs == 9 and .duplicate_ids == 1 and .fixture_jobs == 9'
reject_jobs_with_summary '.[1].jobs[0].run_attempt = 1' \
  '.fixture_invalid == 1 and .fixture_jobs == 9 and .duplicate_ids == 0 and .fixture_wrong_attempt == 1 and .fixture_not_completed == 0 and .fixture_wrong_run == 0'
reject_jobs_with_summary '.[1].jobs[0].status = "in_progress"' \
  '.fixture_invalid == 1 and .fixture_jobs == 9 and .fixture_not_completed == 1 and .fixture_wrong_attempt == 0 and .fixture_not_success == 0'
# Every fixture rejected at once must still say which invariant each job failed.
reject_jobs_with_summary 'map(.jobs |= map(.status = "in_progress" | .conclusion = null))' \
  '.fixture_invalid == 9 and .fixture_not_completed == 9 and .fixture_not_success == 9 and .fixture_wrong_head == 0 and .fixture_bad_steps == 0'
reject_jobs_with_summary '.[0].jobs[1].head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .[1].jobs[1].steps += .[1].jobs[1].steps' \
  '.fixture_invalid == 2 and .fixture_wrong_head == 1 and .fixture_bad_steps == 1 and .fixture_wrong_run == 0 and .fixture_bad_id == 0'
reject_jobs_with_summary '.[1].jobs[0].name += " unexpected"' \
  '.fixture_jobs == 9 and .fixture_invalid == 0 and .fixture_unexpected_names == 1 and .fixture_missing_names == 1'
reject_jobs_with_summary '.[1].jobs[2].steps += ["not-a-step"]' \
  '.fixture_invalid == 1 and .fixture_bad_steps == 1 and .fixture_not_completed == 0'
reject_jobs_with_summary '. + [range(10;22) | {total_count:.,jobs:[]}]' \
  '.pages == 14 and .total_count_variants == 13 and (.reported_totals | length == 8)'
# Only scalar counts may leave rejected evidence; never echo native names,
# identifiers, arbitrary response text or parser diagnostics.
reject_jobs_with_summary '.[0].total_count = "private-response-sentinel"' \
  '. == {state:"invalid_shape"}'
if grep -q 'private-response-sentinel' "$scratch/error"; then fail 'diagnostic disclosed raw evidence'; fi
printf 'not-json private-response-sentinel\n' >"$scratch/jobs.json"
if check pr >"$scratch/out" 2>"$scratch/error"; then fail 'malformed evidence passed'; fi
[[ ! -s "$scratch/out" ]] || fail 'malformed evidence published success'
grep -qx 'native-go-cache: job-evidence-summary={"state":"unreadable"}' "$scratch/error" || fail 'malformed evidence lacks a safe diagnostic'
if grep -q 'private-response-sentinel' "$scratch/error"; then fail 'parser disclosed raw evidence'; fi
for evidence in '' '   ' '{} {}'; do
  printf '%s\n' "$evidence" >"$scratch/jobs.json"
  if check pr >"$scratch/out" 2>"$scratch/error"; then fail 'empty or multiple-root evidence passed'; fi
  [[ ! -s "$scratch/out" ]] || fail 'invalid JSON stream published success'
  grep -qx 'native-go-cache: job-evidence-summary={"state":"unreadable"}' "$scratch/error" || fail 'invalid JSON stream lacks one safe diagnostic'
done
cp "$scratch/good-jobs.json" "$scratch/jobs.json"
cp "$scratch/logs/108.log" "$scratch/good-scan.log"
printf 'Cache saved with the key: setup-go-unsafe\n' >>"$scratch/logs/108.log"
if check pr >"$scratch/out" 2>"$scratch/error"; then fail 'implicit setup-go save was accepted'; fi
cp "$scratch/good-scan.log" "$scratch/logs/108.log"
printf '##[group]Run actions/cache/restore@x\n  key: wrong\n##[endgroup]\nCache not found for input keys: wrong\n' >"$scratch/logs/108.log"
if check pr >"$scratch/out" 2>"$scratch/error"; then fail 'scanner without the expected module restore was accepted'; fi
cp "$scratch/good-scan.log" "$scratch/logs/108.log"
# Preserve the requested key while corrupting the actual outcome. A successful
# REST step does not establish that the allowed archive was restored.
for id in 101 102 103 104 105 106 107 108; do
  cp "$scratch/logs/$id.log" "$scratch/before-outcome.log"
  for outcome in 'Cache restored from key: other-module-key' 'Cache restored from key: ' 'Cache not found for input keys: wrong'; do
    sed '/^Cache /d' "$scratch/before-outcome.log" >"$scratch/logs/$id.log"
    printf '%s\n' "$outcome" >>"$scratch/logs/$id.log"
    if check pr >"$scratch/out" 2>"$scratch/error"; then fail "unbound restore outcome accepted in job $id: $outcome"; fi
  done
  cp "$scratch/before-outcome.log" "$scratch/logs/$id.log"
done
# The scanner's supported timeout retry legitimately restores twice. Both
# observations must be examined rather than accepting an arbitrary one.
jq '.[1].jobs[4].steps = [{name:"🛡️ Scan for known vulnerabilities",status:"completed",conclusion:"failure"},{name:"🛡️ Scan for known vulnerabilities (retry after timeout)",status:"completed",conclusion:"success"}]' "$scratch/good-jobs.json" >"$scratch/jobs.json"
cat "$scratch/good-scan.log" "$scratch/good-scan.log" >"$scratch/logs/108.log"
check pr >"$scratch/out" 2>"$scratch/error" || fail "legitimate scanner retry was rejected: $(cat "$scratch/error")"
cp "$scratch/good-jobs.json" "$scratch/jobs.json"
cp "$scratch/good-scan.log" "$scratch/logs/108.log"
jq '.event="push"' "$scratch/run.json" >"$scratch/run-next.json"
mv "$scratch/run-next.json" "$scratch/run.json"
jq '.[1].jobs[1].steps[1].conclusion="success"' "$scratch/good-jobs.json" >"$scratch/jobs.json"
printf 'Cache saved with key: %s\n' "$key" >>"$scratch/logs/105.log"
jq -n --arg key "$key" '[{total_count:1,actions_caches:[{id:44,key:$key,ref:"refs/heads/main",size_in_bytes:14519689}]}]' >"$scratch/caches.json"
check main >"$scratch/out" 2>"$scratch/error" || fail "real main archive save must pass: $(cat "$scratch/error")"
cp "$scratch/caches.json" "$scratch/good-caches.json"
for mutation in '.[0].actions_caches[0].size_in_bytes=0' '.[0].actions_caches[0].ref="refs/pull/1/merge"' '.[0].actions_caches=[]' '.[0].actions_caches += [.[0].actions_caches[0]] | .[0].total_count=2'; do
  jq "$mutation" "$scratch/good-caches.json" >"$scratch/caches.json"
  if check main >"$scratch/out" 2>"$scratch/error"; then fail "bad main archive accepted: $mutation"; fi
done
cp "$scratch/good-caches.json" "$scratch/caches.json"
cp "$scratch/good-jobs.json" "$scratch/jobs.json"
printf '##[group]Run actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9\n  key: %s\n##[endgroup]\nCache restored from key: %s\n' "$key" "$key" >"$scratch/logs/105.log"
check main >"$scratch/out" 2>"$scratch/error" || fail "second main run must reuse the archive without saving: $(cat "$scratch/error")"
rm "$scratch/logs/103.log"
if check main >"$scratch/out" 2>"$scratch/error"; then fail 'missing job log was accepted'; fi
# Exercise the shipped collector too: a successful API call is not a verdict.
cp "$scratch/good-scan.log" "$scratch/logs/103.log"
mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OBSERVER_FIXTURE/calls"
case "$*" in
  'api --help')
    [[ "${FAIL_HELP_READ:-false}" != true ]] || exit 1
    if [[ "${MODERN_CLI:-false}" == true ]]; then printf '      --allow-escape-sequences   Allow printing terminal escape sequences\n'; else printf '      --include   Include HTTP response status line\n'; fi ;;
  'api repos/devantler-tech/.github/actions/runs/23/attempts/2') cat "$OBSERVER_FIXTURE/run.json" ;;
  'api --paginate --slurp repos/devantler-tech/.github/actions/runs/23/attempts/2/jobs?per_page=50')
    [[ "${FAIL_JOB_READ:-false}" != true ]] || exit 1
    reads="$(grep -c "/jobs?per_page=50\$" "$OBSERVER_FIXTURE/calls")"
    if (( reads <= ${LAG_READS:-0} )); then cat "$OBSERVER_FIXTURE/${LAG_JOBS:-lagging-jobs.json}"; else cat "$OBSERVER_FIXTURE/jobs.json"; fi ;;
  'api repos/devantler-tech/.github/actions/jobs/'*'/logs')
    [[ "${MODERN_CLI:-false}" != true ]] || exit 1
    id="${*: -1}"; id="${id%/logs}"; id="${id##*/}"
    [[ "$id" =~ ^10[1-8]$ ]] || exit 99
    cat "$OBSERVER_FIXTURE/logs/$id.log" ;;
  'api --allow-escape-sequences repos/devantler-tech/.github/actions/jobs/'*'/logs')
    [[ "${MODERN_CLI:-false}" == true ]] || exit 1
    id="${*: -1}"; id="${id%/logs}"; id="${id##*/}"
    [[ "$id" =~ ^10[1-8]$ ]] || exit 99
    cat "$OBSERVER_FIXTURE/logs/$id.log" ;;
  'api --paginate --slurp repos/devantler-tech/.github/actions/caches?per_page=100&key='*'&ref=refs%2Fheads%2Fmain')
    [[ "${FAIL_CACHE_READ:-false}" != true ]] || exit 1
    cat "$OBSERVER_FIXTURE/caches.json" ;;
  *) exit 99 ;;
esac
SH
chmod +x "$scratch/bin/gh"
cat >"$scratch/bin/sleep" <<'SH'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >>"$OBSERVER_FIXTURE/calls"
SH
chmod +x "$scratch/bin/sleep"
# A finished fixture job the jobs API still reports as running (#655).
jq '.[1].jobs[3].status = "in_progress" | .[1].jobs[3].conclusion = null' "$scratch/jobs.json" >"$scratch/lagging-jobs.json"
jq '.[1].jobs[3].status = "completed" | .[1].jobs[3].conclusion = "failure"' "$scratch/jobs.json" >"$scratch/failed-jobs.json"
jq '.[1].jobs[3].status = "in_progress" | .[1].jobs[3].conclusion = null | .[1].jobs[2].head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$scratch/jobs.json" >"$scratch/lagging-stale-jobs.json"
export OBSERVER_FIXTURE="$scratch" GITHUB_REPOSITORY=devantler-tech/.github
export GITHUB_RUN_ID=23 GITHUB_RUN_ATTEMPT=2 EXPECTED_HEAD="$head" MODULE_CACHE_KEY="$key"
export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
PATH="$scratch/bin:$PATH" bash "$helper" observe >"$scratch/out" 2>"$scratch/error" || fail "native collector rejected complete evidence: $(cat "$scratch/error")"
[[ "$(grep -c '^api repos/devantler-tech/.github/actions/jobs/' "$scratch/calls")" == 8 ]] || fail 'collector did not read all eight Go logs'
PATH="$scratch/bin:$PATH" MODERN_CLI=true bash "$helper" observe >"$scratch/out" 2>"$scratch/error" || fail "modern CLI raw-log collector rejected complete evidence: $(cat "$scratch/error")"
if PATH="$scratch/bin:$PATH" FAIL_HELP_READ=true bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'unknown CLI download capability passed'; fi
[[ ! -s "$scratch/out" ]] || fail 'unknown CLI capability published success'
if PATH="$scratch/bin:$PATH" FAIL_JOB_READ=true bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'failed paginated job read passed'; fi
[[ ! -s "$scratch/out" ]] || fail 'failed job read published success'
if PATH="$scratch/bin:$PATH" FAIL_CACHE_READ=true bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'failed archive read passed'; fi
[[ ! -s "$scratch/out" ]] || fail 'failed archive read published success'
if PATH="$scratch/bin:$PATH" GITHUB_REPOSITORY=other/fixture bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'collector admitted another repository'; fi
if PATH="$scratch/bin:$PATH" GITHUB_RUN_ATTEMPT=1 bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'collector admitted another attempt'; fi
# A lagging fixture status is re-read a bounded number of times (#655).
count_calls() { grep -c "$1" "$scratch/calls" || true; }
: >"$scratch/calls"
PATH="$scratch/bin:$PATH" LAG_READS=2 bash "$helper" observe >"$scratch/out" 2>"$scratch/error" || fail "collector rejected a status lag that cleared: $(cat "$scratch/error")"
grep -q 'PASS: native Go cache policy' "$scratch/out" || fail 'cleared status lag did not publish a verdict'
[[ "$(count_calls '/jobs?per_page=50$')" == 3 && "$(count_calls '^sleep 15$')" == 2 ]] || fail 'cleared status lag was not re-read exactly until final'
: >"$scratch/calls"
if PATH="$scratch/bin:$PATH" LAG_READS=99 bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail 'a status lag that never cleared passed'; fi
[[ ! -s "$scratch/out" ]] || fail 'persistent status lag published success'
[[ "$(count_calls '/jobs?per_page=50$')" == 6 && "$(count_calls '^sleep ')" == 5 ]] || fail 'persistent status lag was not bounded to six reads'
grep -q '"fixture_not_completed":1' "$scratch/error" || fail 'persistent status lag lacks its diagnostic'
for evidence in failed-jobs.json lagging-stale-jobs.json; do
  : >"$scratch/calls"
  if PATH="$scratch/bin:$PATH" LAG_READS=99 LAG_JOBS="$evidence" bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then fail "re-read admitted $evidence"; fi
  [[ "$(count_calls '/jobs?per_page=50$')" == 1 && "$(count_calls '^sleep ')" == 0 ]] || fail "$evidence was re-read instead of rejected at once"
done
# A completed, successful job can arrive before its step rows (#735). The
# collector must obtain complete step evidence before evaluating the unchanged
# cache policy; a successful job alone never establishes a successful restore.
jq 'map(.jobs |= map(.steps = []))' "$scratch/jobs.json" >"$scratch/empty-steps-jobs.json"
jq '.[1].jobs[4].steps = []' "$scratch/jobs.json" >"$scratch/empty-scanner-jobs.json"
jq '.[1].jobs[1].steps |= map(select(.name != "Save Go module cache"))' "$scratch/jobs.json" >"$scratch/missing-save-jobs.json"
jq 'map(.jobs |= map(.steps = [{name:"Set up job",status:"completed",conclusion:"success"}]))' "$scratch/jobs.json" >"$scratch/partial-steps-jobs.json"
cp "$scratch/run.json" "$scratch/collector-main-run.json"
for collector_mode in main pr; do
  if [[ "$collector_mode" == pr ]]; then
    jq '.event = "pull_request"' "$scratch/collector-main-run.json" >"$scratch/run.json"
    export GITHUB_EVENT_NAME=pull_request GITHUB_REF=refs/pull/37/merge
  fi
  for evidence in empty-steps-jobs.json empty-scanner-jobs.json missing-save-jobs.json partial-steps-jobs.json; do
    : >"$scratch/calls"
    PATH="$scratch/bin:$PATH" LAG_READS=2 LAG_JOBS="$evidence" bash "$helper" observe >"$scratch/out" 2>"$scratch/error" ||
      fail "collector rejected completed jobs whose step metadata later arrived ($collector_mode, $evidence): $(cat "$scratch/error")"
    grep -q 'PASS: native Go cache policy' "$scratch/out" || fail 'hydrated step evidence did not reach the real policy check'
    [[ "$(count_calls '/jobs?per_page=50$')" == 3 && "$(count_calls '^sleep 15$')" == 2 ]] ||
      fail 'step hydration did not stop as soon as complete evidence arrived'
  done
done
cp "$scratch/collector-main-run.json" "$scratch/run.json"
export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
for evidence in empty-steps-jobs.json empty-scanner-jobs.json missing-save-jobs.json; do
  : >"$scratch/calls"
  if PATH="$scratch/bin:$PATH" LAG_READS=99 LAG_JOBS="$evidence" bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then
    fail "persistent missing step evidence passed ($evidence)"
  fi
  [[ ! -s "$scratch/out" ]] || fail 'incomplete step evidence published success'
  [[ "$(count_calls '/jobs?per_page=50$')" == 6 && "$(count_calls '^sleep 15$')" == 5 ]] ||
    fail 'step hydration was not bounded to the existing six reads'
done
# Missing rows never make a contradictory identity, unsuccessful job or known
# failed restore eligible for another read that might hide the rejection.
jq '.[0].jobs[1].head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$scratch/empty-steps-jobs.json" >"$scratch/empty-stale-jobs.json"
jq '.[0].jobs[1].conclusion = "failure"' "$scratch/empty-steps-jobs.json" >"$scratch/empty-failed-jobs.json"
jq '.[0].jobs[1].steps = [{name:"Restore Go module cache",status:"completed",conclusion:"failure"}]' "$scratch/empty-steps-jobs.json" >"$scratch/empty-bad-restore-jobs.json"
for evidence in empty-stale-jobs.json empty-failed-jobs.json empty-bad-restore-jobs.json; do
  : >"$scratch/calls"
  if PATH="$scratch/bin:$PATH" LAG_READS=99 LAG_JOBS="$evidence" bash "$helper" observe >"$scratch/out" 2>"$scratch/error"; then
    fail "contradictory evidence passed during hydration ($evidence)"
  fi
  [[ ! -s "$scratch/out" ]] || fail 'contradictory evidence published success'
  [[ "$(count_calls '/jobs?per_page=50$')" == 1 && "$(count_calls '^sleep ')" == 0 ]] ||
    fail 'contradictory evidence was retried instead of rejected immediately'
done
printf 'PASS: native cache observer accepts PR, main save and main reuse; bounds job and step hydration; rejects incomplete and unsafe evidence\n'
