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

bin="$tmp/bin"
mkdir "$bin"
cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"${GH_LOG:?}"
case "$2" in
  orgs/fix/repos) printf 'false\texample\ntrue\tretired\n' ;;
  orgs/fix) echo "${EXPECTED_REPOS-2}" ;;
  "repos/fix/example/actions/workflows?per_page=100")
    if [ "${FAIL_WORKFLOWS-}" = 1 ]; then
      echo 'gh: unavailable' >&2
      exit 1
    fi
    printf '11\t.github/workflows/ci.yaml\n12\t.github/workflows/manual.yaml\n13\tdynamic/dependabot/dependabot-updates\n'
    ;;
  "repos/fix/example/actions/workflows/11/runs?per_page=100&created=%3E%3D2026-08-20")
    printf 'push\tactor\tdependabot[bot]\tBot\t49699333\n'
    printf 'push\ttriggering_actor\tdevantler\tUser\t26203420\n'
    # Duplicate observations collapse to one evidence row.
    printf 'push\tactor\tdependabot[bot]\tBot\t49699333\n'
    if [ "${FAIL_RUNS-}" = 1 ]; then
      echo 'gh: page 2 unavailable' >&2
      exit 1
    fi
    ;;
  "repos/fix/example/actions/workflows/12/runs?per_page=100&created=%3E%3D2026-08-20") ;;
  users/dependabot%5Bbot%5D)
    [ "${UNREADABLE_ACTOR-}" != 1 ] || { echo 'gh: unavailable' >&2; exit 1; }
    [ "${MISMATCH_ACTOR-}" != 1 ] && printf '49699333\tBot\n' || printf '1\tBot\n'
    ;;
  users/devantler) printf '26203420\tUser\n' ;;
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

# A run-history ID that disagrees with the live actor record is UNKNOWN, never usable evidence.
rc=0
out="$(MISMATCH_ACTOR=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "an actor mismatch must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "an actor mismatch must emit UNKNOWN for the affected workflow"
grep -Fq "$actor_row" <<<"$out" && fail "mismatched actor evidence must not leak as OBSERVED"

# Partial output followed by an API failure is discarded and reported as UNKNOWN.
rc=0
out="$(FAIL_RUNS=1 PATH="$bin:$PATH" bash "$inventory" --org fix --since 2026-08-20 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "a partial run-history read must exit 2, got $rc"
grep -Fq "$(printf 'example\t.github/workflows/ci.yaml\tUNKNOWN')" <<<"$out" ||
  fail "a partial run-history read must emit UNKNOWN"
grep -Fq "$actor_row" <<<"$out" && fail "partial run history must not emit OBSERVED rows"

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
