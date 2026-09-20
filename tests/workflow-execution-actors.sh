#!/usr/bin/env bash
# Pins the workflow actor evidence inventory against offline GitHub API fixtures.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$repo_root/scripts/workflow-execution-actors.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "workflow-execution-actors test: $*" >&2
  exit 1
}

assert_no_ci_observed() {
  local output="$1" reason="$2"
  if awk -F '\t' '
    $1 == "example" && $2 == ".github/workflows/ci.yaml" && $8 == "OBSERVED" { found=1 }
    END { exit(found ? 0 : 1) }
  ' <<<"$output"; then
    fail "$reason must not emit any OBSERVED row for the affected workflow"
  fi
}

bin="$tmp/bin"
mkdir "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
endpoint="$2"
printf '%s\n' "$endpoint" >>"${GH_LOG:?}"
jq_filter=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--jq" ]; then
    jq_filter="${2:?missing jq filter}"
    break
  fi
  shift
done

emit_json() {
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter"
  else
    cat
  fi
}

case "$endpoint" in
  orgs/fix/repos)
    if [ "${EMPTY_ORG-}" = 1 ]; then
      printf '%s\n' '[]' | emit_json
    else
      printf '%s\n' '[{"archived":false,"name":"example"},{"archived":true,"name":"retired"}]' | emit_json
    fi
    ;;
  orgs/fix)
    printf '{"public_repos":%s,"total_private_repos":0}\n' "${EXPECTED_REPOS-2}" | emit_json
    ;;
  "repos/fix/example/actions/workflows?per_page=100")
    if [ "${FAIL_WORKFLOWS-}" = 1 ]; then
      echo 'gh: unavailable' >&2
      exit 1
    fi
    printf '%s\n' '{"workflows":[{"id":11,"path":".github/workflows/ci.yaml","state":"active"},{"id":12,"path":".github/workflows/manual.yaml","state":"active"},{"id":13,"path":"dynamic/dependabot/dependabot-updates","state":"active"}]}' | emit_json
    ;;
  "repos/fix/example/actions/workflows/11/runs?per_page=100&created=%3E%3D2026-08-20")
    if [ "${NULL_ACTOR-}" = 1 ]; then
      printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":104,"run_attempt":1,"event":"push","actor":null,"triggering_actor":null}]}' | emit_json
    elif [ "${RERUN_ACTORS-}" = 1 ]; then
      printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":103,"run_attempt":3,"event":"push","actor":{"login":"devantler","type":"User","id":26203420},"triggering_actor":{"login":"devantler","type":"User","id":26203420}}]}' | emit_json
    elif [ "${CAPPED_RUNS-}" = 1 ]; then
      jq -nc '{total_count:1000,workflow_runs:[range(1;1001) | {id:.,run_attempt:1,event:"push",actor:{login:"dependabot[bot]",type:"Bot",id:49699333},triggering_actor:{login:"dependabot[bot]",type:"Bot",id:49699333}}]}' | emit_json
    else
      printf '%s\n' '{"total_count":2,"workflow_runs":[{"id":101,"run_attempt":1,"event":"push","actor":{"login":"dependabot[bot]","type":"Bot","id":49699333},"triggering_actor":{"login":"devantler","type":"User","id":26203420}},{"id":102,"run_attempt":1,"event":"push","actor":{"login":"dependabot[bot]","type":"Bot","id":49699333},"triggering_actor":{"login":"dependabot[bot]","type":"Bot","id":49699333}}]}' | emit_json
    fi
    if [ "${FAIL_RUNS-}" = 1 ]; then
      echo 'gh: page 2 unavailable' >&2
      exit 1
    fi
    ;;
  "repos/fix/example/actions/workflows/12/runs?per_page=100&created=%3E%3D2026-08-20")
    printf '%s\n' '{"total_count":0,"workflow_runs":[]}' | emit_json
    ;;
  "repos/fix/example/actions/runs/103/attempts/1")
    printf '%s\n' '{"id":103,"run_attempt":1,"event":"push","actor":{"login":"devantler","type":"User","id":26203420},"triggering_actor":{"login":"devantler","type":"User","id":26203420}}' | emit_json
    ;;
  "repos/fix/example/actions/runs/103/attempts/2")
    if [ "${FAIL_ATTEMPT-}" = 1 ]; then
      echo 'gh: unavailable' >&2
      exit 1
    fi
    printf '%s\n' '{"id":103,"run_attempt":2,"event":"push","actor":{"login":"devantler","type":"User","id":26203420},"triggering_actor":{"login":"octocat","type":"User","id":583231}}' | emit_json
    ;;
  users/dependabot%5Bbot%5D)
    [ "${UNREADABLE_ACTOR-}" != 1 ] || { echo 'gh: unavailable' >&2; exit 1; }
    [ "${MISMATCH_ACTOR-}" != 1 ] && printf '49699333\tBot\n' || printf '1\tBot\n'
    ;;
  users/devantler) printf '26203420\tUser\n' ;;
  users/octocat) printf '583231\tUser\n' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/gh"

export GH_LOG="$tmp/gh.log"
out="$(PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20)" ||
  fail "complete evidence must exit 0"

header=$'repo\tworkflow\tevent\tactor_role\tactor_login\tactor_type\tactor_id\tevidence'
[ "$(head -1 <<<"$out")" = "$header" ] || fail "missing or wrong header"

actor_row="$(printf 'example\t.github/workflows/ci.yaml\tpush\tactor\tdependabot[bot]\tBot\t49699333\tOBSERVED')"
rerun_row="$(printf 'example\t.github/workflows/ci.yaml\tpush\ttriggering_actor\tdevantler\tUser\t26203420\tOBSERVED')"
no_runs_row="$(printf 'example\t.github/workflows/manual.yaml\tNO-RUNS\t-\t-\t-\t-\tNO-RUNS')"
[ "$(grep -Fxc "$actor_row" <<<"$out")" -eq 1 ] || fail "duplicate actor observations must collapse"
grep -Fxq "$rerun_row" <<<"$out" || fail "the rerunning actor must stay distinct from the original actor"
grep -Fxq "$no_runs_row" <<<"$out" || fail "a workflow with no runs must say NO-RUNS"
grep -Fq 'dynamic/' <<<"$out" && fail "GitHub feature workflows are not repository workflow files"
[ "$(grep -c '^users/dependabot%5Bbot%5D$' "$GH_LOG")" -eq 1 ] || fail "each actor must resolve once"

# An organization with no repositories has complete empty evidence, not an unexplained shell error.
rc=0
out="$(EMPTY_ORG=1 EXPECTED_REPOS=0 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] || fail "an empty organization must exit 0, got $rc"
[ "$out" = "$header" ] || fail "an empty organization must emit only the header"

# GitHub may truncate created-filtered workflow-run searches at exactly 1,000 results.
rc=0
out="$(CAPPED_RUNS=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a capped run search must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "a capped run search must emit UNKNOWN"

# Deleted or unreadable actors remain unresolved evidence, not NO-RUNS.
rc=0
out="$(NULL_ACTOR=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a null historical actor must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "a null historical actor must emit UNKNOWN"

# Every attempt contributes actor evidence, even when the latest rerun actor matches the original.
out="$(RERUN_ACTORS=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20)" ||
  fail "complete rerun-attempt evidence must exit 0"
attempt_actor_row="$(printf 'example\t.github/workflows/ci.yaml\tpush\ttriggering_actor\toctocat\tUser\t583231\tOBSERVED')"
grep -Fxq "$attempt_actor_row" <<<"$out" || fail "an earlier rerun actor must remain observed"

# A missing attempt invalidates the whole workflow rather than leaking newer-attempt evidence.
rc=0
out="$(RERUN_ACTORS=1 FAIL_ATTEMPT=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a missing rerun attempt must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "a missing rerun attempt must emit UNKNOWN"
assert_no_ci_observed "$out" "partial rerun-attempt history"

# A run-history ID that disagrees with the live actor record is UNKNOWN, never usable evidence.
rc=0
out="$(MISMATCH_ACTOR=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "an actor mismatch must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "an actor mismatch must emit UNKNOWN for the affected workflow"
assert_no_ci_observed "$out" "mismatched actor evidence"

# Partial output followed by an API failure is discarded and reported as UNKNOWN.
rc=0
out="$(FAIL_RUNS=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a partial run-history read must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "a partial run-history read must emit UNKNOWN"
assert_no_ci_observed "$out" "partial run history"

# Repository/workflow discovery also fails closed.
rc=0
out="$(FAIL_WORKFLOWS=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "an unreadable workflow listing must exit 2, got $rc"
grep -Fq "$(printf 'example\tUNKNOWN')" <<<"$out" || fail "an unreadable workflow listing must emit UNKNOWN"

# A selected-repository token can return a successful but incomplete org listing.
rc=0
EXPECTED_REPOS=3 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "an incomplete repository listing must exit 2, got $rc"

echo "workflow-execution-actors test: ok"
