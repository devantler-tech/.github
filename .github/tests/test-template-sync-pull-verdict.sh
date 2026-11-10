#!/usr/bin/env bash

# A template pull that fails must fail Template Sync, never pass with no proposal (#887).
#
# The pinned action runs `git pull` with the workflow's parameters, ignores a nonzero result, and
# exits 0 with "nothing to commit" when nothing was staged. The workflow's precommit hook is the
# verdict. This reads the hook commands and pull parameters from the workflow itself, replays the
# action's own sequence on real git fixtures (branch, pull with the failure swallowed, restore the
# ignore file, run each hook as `echo "$command" | bash`), and checks every outcome: a normal
# change and a genuine no-change pass; an unreachable source, a missing branch, a refused merge and
# a conflicting merge fail with the matching annotation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$repo_root/.github/workflows/template-sync.yaml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v yq >/dev/null || fail "yq is required (the action itself needs it to run hooks)"

step='.jobs.template-sync.steps[] | select((.uses // "") | contains("AndreasAugustin/actions-template-sync@"))'
allow_hooks="$(yq -r "$step | .with.is_allow_hooks // \"\"" "$workflow")"
[[ "$allow_hooks" == "true" ]] || fail "the sync step must set is_allow_hooks: true, or the pull verdict never runs"
hooks="$(yq -r "$step | .with.hooks // \"\"" "$workflow")"
[[ -n "$hooks" ]] || fail "the sync step must pass its hooks inline, so a caller file never supplies them"
pull_params="$(yq -r "$step | .with.git_remote_pull_params // \"\"" "$workflow")"
[[ " $pull_params " == *" --squash "* ]] ||
  fail "the pull verdict relies on SQUASH_MSG, so the pull parameters must keep --squash: $pull_params"
[[ " $pull_params " == *" --no-tags "* ]] || fail "the pull parameters must keep --no-tags (#861): $pull_params"

test_root="$(mktemp -d)"
pull_verdict_finished=0
cleanup() {
  local rc=$?
  rm -rf "$test_root"
  if [[ "$pull_verdict_finished" != 1 && "$rc" -eq 0 ]]; then
    echo "FAIL: aborted before finishing" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

# The action reads hooks with `yq "<hook>.commands | .[]"` from a copy of the input (cmd_from_yml).
printf '%s\n' "$hooks" > "$test_root/hooks.yml"
commands=()
while IFS= read -r line; do
  commands+=("$line")
done < <(yq '.precommit.commands | .[]' "$test_root/hooks.yml")
[[ "${#commands[@]}" -ge 2 ]] || fail "expected the pull and the conflict checks as precommit commands, found ${#commands[@]}"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
g() { git -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

template="$test_root/template"
g init -q "$template"
printf 'shared\n' > "$template/shared.txt"
printf 'template-owned\n' > "$template/.templatesyncignore"
g -C "$template" add .
g -C "$template" commit -qm "template 1"

# new_consumer <name>: a consumer with its own history and ignore file.
new_consumer() {
  local dir="$test_root/$1"
  g init -q "$dir"
  g -C "$dir" config pull.rebase false
  printf 'mine\n' > "$dir/own.txt"
  printf 'own.txt\n' > "$dir/.templatesyncignore"
  g -C "$dir" add .
  g -C "$dir" commit -qm "consumer 1"
  printf '%s\n' "$dir"
}

printf '%s\n' "${commands[@]}" > "$test_root/commands"

# The replay runs as its own `bash -e` process, as the action's script does, so a failing hook
# aborts it the way it aborts the action. (Inside a caller's `|| rc=$?`, `set -e` is ignored.)
cat > "$test_root/replay.sh" <<'EOF'
set -e
dir="$1" source="$2" ref="$3" pull_params="$4" commands_file="$5"
cd "$dir"
git checkout -q -b chore/template-sync_test
# sync_template.sh: eval "git pull ${source_repo} --tags ${git_remote_pull_params} ${ref}" || pull_has_issues=true
eval "git pull \"$source\" --tags $pull_params $ref" >/dev/null 2>&1 || pull_has_issues=true
# restore_templatesyncignore_file
if [ -s .templatesyncignore ]; then
  git reset -q .templatesyncignore >/dev/null 2>&1
  git checkout -- .templatesyncignore 2>/dev/null || true
fi
# cmd_from_yml "precommit": for key in "${cmd_Arr[@]}"; do echo "${key}" | bash; done
while IFS= read -r command; do
  echo "$command" | bash
done < "$commands_file"
EOF

# replay <consumer> <source> <ref>: the action's pull and precommit sequence. Prints the hook
# output and returns the status the action would end with.
replay() {
  bash "$test_root/replay.sh" "$1" "$2" "$3" "$pull_params" "$test_root/commands"
}

# expect <name> <pass|fail> <annotation or -> <consumer> <source> <ref>
expect() {
  local name="$1" want="$2" needle="$3" rc=0
  shift 3
  replay "$@" > "$test_root/out" 2>&1 || rc=$?
  if [[ "$want" == pass && "$rc" -ne 0 ]]; then
    fail "$name: the hook failed a good pull: $(cat "$test_root/out")"
  fi
  if [[ "$want" == fail && "$rc" -eq 0 ]]; then
    fail "$name: the hook passed a failed pull: $(cat "$test_root/out")"
  fi
  if [[ "$needle" != "-" ]] && ! grep -qF -- "$needle" "$test_root/out"; then
    fail "$name: output lacks \"$needle\": $(cat "$test_root/out")"
  fi
  echo "ok   $name"
}

# A normal change passes and leaves the template's file staged for the action's commit.
c="$(new_consumer normal)"
expect "normal change passes" pass - "$c" "$template" main
staged="$(g -C "$c" diff --cached --name-only)"
grep -qx shared.txt <<<"$staged" || fail "normal change: shared.txt is not staged"
[[ "$(cat "$c/.templatesyncignore")" == "own.txt" ]] || fail "normal change: the caller's ignore file was not kept"
echo "ok   normal change stages the template file and keeps the caller's ignore file"

# A consumer that already holds the template's content passes with nothing staged.
c="$(new_consumer synced)"
replay "$c" "$template" main >/dev/null
g -C "$c" commit -qm "earlier sync"
g -C "$c" checkout -q main
g -C "$c" merge -q --ff-only chore/template-sync_test
g -C "$c" branch -q -D chore/template-sync_test
expect "genuine no-change passes" pass - "$c" "$template" main
[[ -z "$(g -C "$c" diff --cached --name-only)" ]] || fail "genuine no-change: something was staged"

c="$(new_consumer unreachable)"
expect "unreachable source fails" fail "::error title=Template pull failed::" "$c" "$test_root/missing-template" main

c="$(new_consumer missing-branch)"
expect "missing branch fails" fail "::error title=Template pull failed::" "$c" "$template" no-such-branch

# An untracked file the merge would overwrite makes git refuse the merge before it starts.
c="$(new_consumer refused)"
printf 'local\n' > "$c/shared.txt"
expect "refused merge fails" fail "::error title=Template pull failed::" "$c" "$template" main

# A file in the consumer where the template now has a directory cannot be resolved by -X theirs.
c="$(new_consumer conflict)"
printf 'file\n' > "$c/tree"
g -C "$c" add tree
g -C "$c" commit -qm "a file named tree"
conflict_template="$test_root/conflict-template"
g clone -q "$template" "$conflict_template"
mkdir "$conflict_template/tree"
printf 'nested\n' > "$conflict_template/tree/leaf.txt"
g -C "$conflict_template" add tree
g -C "$conflict_template" commit -qm "a directory named tree"
expect "conflicting merge fails" fail "::error title=Template merge conflict::" "$c" "$conflict_template" main

pull_verdict_finished=1
echo "Template Sync pull verdict: all cases held"
