#!/usr/bin/env bash
# Read-only native evidence for the catalogue's dependency-bearing Go caller.
set -euo pipefail
export LC_ALL=C
prefix='[Test] Validate Go Project - Isolated PostgreSQL / '
fail() { printf 'native-go-cache: %s\n' "$*" >&2; exit 2; }
validate_jobs() {
  jq -e --argjson run "$run" --argjson attempt "$attempt" --arg head "$head" --arg prefix "$prefix" '
    def positive: type == "number" and . > 0 and floor == .;
    type == "array" and length > 0 and
    all(.[]; (.total_count | positive) and (.jobs | type == "array")) and
    ([.[].total_count] | unique | length == 1) and
    ([.[].jobs[]] | length) == .[0].total_count and
    ([.[].jobs[].id] | length == (unique | length)) and
    ([.[].jobs[] | select(.name | startswith($prefix))] as $fixture |
      ($fixture | length == 9) and
      ($fixture | map(.name | ltrimstr($prefix)) | sort) ==
        (["🔍 Detect Changes","🏗️ Build","🧹 Lint - golangci-lint","🔍 Dead Code Analysis","📦 Tidy","🧪 Test","📊 Code Coverage","🧹 Lint - mega-linter","🛡️ Vulnerability Scan"] | sort) and
      all($fixture[]; (.id | positive) and .run_id == $run and .run_attempt == $attempt and .head_sha == $head and
        .status == "completed" and .conclusion == "success" and (.steps | type == "array") and
        ([.steps[].name] | length == (unique | length))))
  ' "$jobs" >/dev/null 2>&1 || fail 'incomplete, stale or unsuccessful current-attempt jobs'
}
normalize_log() {
  sed -E 's/^[0-9]{4}-[0-9T:.+-]+Z //; s/^Cache saved with the key: /Cache saved with key: /' "$1"
}
restore_section() {
  # Select only the action group with this exact key and its following result.
  # Source echoed inside a shell step cannot impersonate a cache-action result.
  normalize_log "$1" | awk -v key="$key" -v expected="$2" '
    /##\[group\]/ {
      if (wanted) { printf "%s", block; matches++; }
      block=""; wanted=0; restore=($0 ~ /##\[group\]Run actions\/cache\/restore@/)
    }
    restore { block=block $0 "\n"; if ($0 == "  key: " key) wanted=1; }
    END { if (wanted) { printf "%s", block; matches++; } if (matches != expected) exit 1; }
  '
}
check() {
  [[ "$#" == 9 ]] || fail 'check needs mode, run, attempt, head, key and four evidence paths'
  mode="$1"; run="$2"; attempt="$3"; head="$4"; key="$5"
  metadata="$6"; jobs="$7"; caches="$8"; logs="$9"
  [[ "$mode" == pr || "$mode" == main ]] || fail 'unsupported observation mode'
  [[ "$run" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]*$ && "$head" =~ ^[a-f0-9]{40}$ ]] || fail 'invalid run identity'
  [[ "$key" =~ ^go-mod-v1-Linux-X64-\.github/tests/go-postgresql-fixture-[a-f0-9]{64}$ ]] || fail 'invalid exact fixture cache key'
  jq -e --argjson run "$run" --argjson attempt "$attempt" --arg head "$head" --arg mode "$mode" '
    .id == $run and .run_attempt == $attempt and .head_sha == $head and
    .repository.full_name == "devantler-tech/.github" and
    (if $mode == "pr" then .event == "pull_request" else .event == "push" end)
  ' "$metadata" >/dev/null 2>&1 || fail 'run metadata does not match the current invocation'
  validate_jobs
  test_id=''; module_save=''; test_restore=''
  while IFS=$'\t' read -r id name; do
    log="$logs/$id.log"
    [[ -s "$log" && ! -L "$log" ]] || fail 'missing native Go job log'
    # Catch implicit setup-go savers too, not just named cache/save steps.
    saved="$(normalize_log "$log" | grep -E '^Cache saved with key: (setup-go-|go-mod-|go-build-)' || true)"
    if [[ "$mode" == pr && -n "$saved" ]]; then fail 'pull request wrote a Go cache archive'; fi
    if [[ "$mode" == main && -n "$saved" ]]; then
      while IFS= read -r archive; do
        case "$name" in
          "${prefix}🧪 Test")
            [[ "$archive" == "Cache saved with key: $key" || "$archive" =~ ^Cache\ saved\ with\ key:\ go-build-v1-Linux-X64-[^[:space:]]+-\.github/tests/go-postgresql-fixture-test-[a-f0-9]{64}$ ]] || fail 'Test saved an unexpected Go archive'
            ;;
          "${prefix}📊 Code Coverage")
            [[ "$archive" =~ ^Cache\ saved\ with\ key:\ go-build-v1-Linux-X64-[^[:space:]]+-\.github/tests/go-postgresql-fixture-coverage-[a-f0-9]{64}$ ]] || fail 'Coverage saved an unexpected Go archive'
            ;;
          *) fail 'non-writer job saved a Go archive' ;;
        esac
      done <<<"$saved"
    fi
    restores=1
    if [[ "$name" == "${prefix}🛡️ Vulnerability Scan" ]]; then
      restores="$(jq -er --argjson id "$id" '
        [.[].jobs[] | select(.id == $id) | .steps[] | select(.name == "🛡️ Scan for known vulnerabilities" and .status == "completed")] as $first |
        [.[].jobs[] | select(.id == $id) | .steps[] | select(.name == "🛡️ Scan for known vulnerabilities (retry after timeout)" and .status == "completed")] as $retry |
        if ($first | length) == 1 and $first[0].conclusion == "success" and (($retry | length) == 0 or (($retry | length) == 1 and $retry[0].conclusion == "skipped")) then 1
        elif ($first | length) == 1 and ($first[0].conclusion == "failure" or $first[0].conclusion == "success") and ($retry | length) == 1 and $retry[0].conclusion == "success" then 2
        else error("incomplete scanner execution") end
      ' "$jobs")" || fail 'scanner did not exercise its module restore'
      [[ -z "$saved" ]] || fail 'scanner wrote a Go archive'
    else
      jq -e --argjson id "$id" '[.[].jobs[] | select(.id == $id) | .steps[] | select(.name == "Restore Go module cache" and .status == "completed" and .conclusion == "success")] | length == 1' "$jobs" >/dev/null || fail 'Go job did not restore its module cache'
    fi
    section="$(restore_section "$log" "$restores")" || fail 'missing or ambiguous exact module restore action'
    outcomes="$(grep -E '^Cache (restored from key:|not found for input keys:)' <<<"$section" || true)"
    [[ "$(grep -c . <<<"$outcomes" || true)" == "$restores" ]] || fail 'module restore action has no unique completed outcome'
    while IFS= read -r outcome; do
      if [[ "$outcome" == 'Cache restored from key: '* ]]; then
        restored_key="${outcome#Cache restored from key: }"
        [[ "$restored_key" == "$key" || ( "$mode" == pr && "$restored_key" == "${key%-*}-"* && "${restored_key#"${key%-*}-"}" =~ ^[a-f0-9]{64}$ ) ]] || fail 'module restore returned a key outside its allowed namespace'
      else
        [[ "$outcome" == "Cache not found for input keys: $key" || ( "$mode" == pr && "$outcome" == "Cache not found for input keys: $key, ${key%-*}-" ) ]] || fail 'module miss did not name the requested key'
      fi
    done <<<"$outcomes"
    if [[ "$name" == "${prefix}🧪 Test" ]]; then
      test_id="$id"; test_restore="$section"
      module_save="$(jq -r --argjson id "$id" '[.[].jobs[] | select(.id == $id) | .steps[] | select(.name == "Save Go module cache" and .status == "completed")] | if length == 1 then .[0].conclusion else "missing" end' "$jobs")"
    fi
  done < <(jq -r --arg prefix "$prefix" '.[].jobs[] | select((.name | startswith($prefix)) and .name != ($prefix + "🔍 Detect Changes")) | [.id,.name] | @tsv' "$jobs")
  [[ -n "$test_id" ]] || fail 'missing Test writer'
  jq -e --arg prefix "$prefix" --arg mode "$mode" '
    [.[].jobs[] | select(.name | startswith($prefix)) |
      .name as $job | .steps[] | select(.name | startswith("Save Go")) | {job:$job,name,status,conclusion}] as $saves |
    ($saves | length == 3) and
    all($saves[]; .status == "completed" and
      (if $mode == "pr" then .conclusion == "skipped" else (.conclusion == "success" or .conclusion == "skipped") end)) and
    ($saves | map(.job + "|" + .name) | sort) ==
      ([$prefix+"🧪 Test|Save Go module cache",$prefix+"🧪 Test|Save Go compilation cache",$prefix+"📊 Code Coverage|Save Go compilation cache"] | sort)
  ' "$jobs" >/dev/null || fail 'Go save steps violate the writer policy'
  if [[ "$mode" == main ]]; then
    # Main restores its exact dependency key; falling back would grow an archive.
    if grep -q '^  restore-keys:' <<<"$test_restore"; then fail 'main module restore used fallback keys'; fi
    if grep -Fxq "Cache restored from key: $key" <<<"$test_restore"; then
      [[ "$module_save" == skipped ]] || fail 'exact main hit saved again'
    elif grep -Fxq "Cache not found for input keys: $key" <<<"$test_restore"; then
      [[ "$module_save" == success ]] || fail 'main module miss did not save'
      [[ "$(normalize_log "$logs/$test_id.log" | grep -Fxc "Cache saved with key: $key" || true)" == 1 ]] || fail 'main miss did not publish its exact archive'
    else
      fail 'main restored a non-exact module archive'
    fi
    jq -e --arg key "$key" '
      type == "array" and length > 0 and
      all(.[]; (.total_count | type == "number") and (.actions_caches | type == "array")) and
      ([.[].total_count] | unique | length == 1) and
      ([.[].actions_caches[]] | length) == .[0].total_count and
      ([.[].actions_caches[].id] | length == (unique | length)) and
      ([.[].actions_caches[] | select(.key == $key and .ref == "refs/heads/main")] as $exact |
        ($exact | length == 1) and ($exact[0].size_in_bytes | type == "number" and . > 0))
    ' "$caches" >/dev/null 2>&1 || fail 'main has no single non-empty exact module archive'
  fi
  printf 'PASS: native Go cache policy (%s, run %s attempt %s): all eight Go restores; expected save policy\n' "$mode" "$run" "$attempt"
}
observe() {
  [[ "$#" == 0 ]] || fail 'observe takes only the trusted workflow environment'
  [[ "${GITHUB_REPOSITORY:-}" == devantler-tech/.github ]] || fail 'observer is catalogue-only'
  run="${GITHUB_RUN_ID:-}"; attempt="${GITHUB_RUN_ATTEMPT:-}"; head="${EXPECTED_HEAD:-}"; key="${MODULE_CACHE_KEY:-}"
  [[ "$run" =~ ^[1-9][0-9]*$ && "$attempt" =~ ^[1-9][0-9]*$ && "$head" =~ ^[a-f0-9]{40}$ ]] || fail 'invalid trusted run identity'
  case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
    pull_request:refs/pull/*/merge) mode='pr' ;;
    push:refs/heads/main) mode=main ;;
    *) fail 'unsupported catalogue invocation' ;;
  esac
  scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"' EXIT
  mkdir "$scratch/logs"
  gh api "repos/devantler-tech/.github/actions/runs/$run/attempts/$attempt" >"$scratch/run.json" || fail 'run metadata read failed'
  gh api --paginate --slurp "repos/devantler-tech/.github/actions/runs/$run/attempts/$attempt/jobs?per_page=100" >"$scratch/jobs.json" || fail 'complete current-attempt job read failed'
  jobs="$scratch/jobs.json"
  validate_jobs
  while IFS= read -r id; do
    gh api "repos/devantler-tech/.github/actions/jobs/$id/logs" >"$scratch/logs/$id.log" || fail 'Go job log read failed'
  done < <(jq -r --arg prefix "$prefix" '.[].jobs[] | select((.name | startswith($prefix)) and .name != ($prefix + "🔍 Detect Changes")) | .id' "$jobs")
  printf '[]\n' >"$scratch/caches.json"
  if [[ "$mode" == main ]]; then
    [[ "$key" =~ ^go-mod-v1-Linux-X64-\.github/tests/go-postgresql-fixture-[a-f0-9]{64}$ ]] || fail 'invalid trusted fixture cache key'
    gh api --paginate --slurp "repos/devantler-tech/.github/actions/caches?per_page=100&key=$key&ref=refs%2Fheads%2Fmain" >"$scratch/caches.json" || fail 'complete archive read failed'
  fi
  check "$mode" "$run" "$attempt" "$head" "$key" "$scratch/run.json" "$scratch/jobs.json" "$scratch/caches.json" "$scratch/logs"
}
command="${1:-}"
shift || true
case "$command" in
  check) check "$@" ;;
  observe) observe "$@" ;;
  *) fail 'expected check or observe' ;;
esac
