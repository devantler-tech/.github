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
reject_jobs_with_summary() {
  reject_jobs "$1"
  local summary
  summary="$(sed -n 's/^native-go-cache: job-evidence-summary=//p' "$scratch/error")"
  [[ -n "$summary" ]] || fail 'rejected jobs have no sanitized diagnostic'
  jq -e '
    if keys == ["state"] then .state | IN("invalid_shape", "unreadable")
    else keys == ["duplicate_ids", "fetched_jobs", "fixture_bad_id", "fixture_bad_steps", "fixture_invalid", "fixture_jobs", "fixture_not_completed", "fixture_not_success", "fixture_wrong_attempt", "fixture_wrong_head", "fixture_wrong_run", "pages", "reported_totals", "total_count_variants"] and
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
    cat "$OBSERVER_FIXTURE/jobs.json" ;;
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
printf 'PASS: native cache observer accepts PR, main save and main reuse; rejects incomplete and unsafe evidence\n'
