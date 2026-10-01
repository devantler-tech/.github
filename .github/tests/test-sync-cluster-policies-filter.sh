#!/usr/bin/env bash
# Execute the shipped filter with an indexed fixture, without credentials or network.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/sync-cluster-policies.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for step in verify-allowlist filter-policies; do
  yq -r ".jobs.sync-policies.steps[] | select(.id == \"$step\") | .run" "$workflow" >"$work/$step.sh"
done
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fixture() {
  rm -rf "$work/caller" "$work/upstream" "$work/runner"
  mkdir -p "$work/caller/target" "$work/upstream/other/nested" "$work/upstream/deep/other" "$work/runner"
  printf 'preserve me\n' >"$work/caller/target/sentinel"
  for file in root.yaml other/keep.yaml other/drop.yaml other/nested/keep.yaml deep/other/drop.yaml directory; do
    printf '%s\n' "$file" >"$work/upstream/$file"
  done
  git -C "$work/upstream" init -q
  git -C "$work/upstream" add root.yaml other deep directory
}
run_filter() {
  (
    cd "$work/caller" && export KYVERNO_POLICIES_TEMP_DIR="$work/upstream" RUNNER_TEMP="$work/runner"
    bash -e "$work/verify-allowlist.sh" || return
    bash -e "$work/filter-policies.sh"
  )
}
case_keeps() {
  local label="$1" pattern="$2" expected="$3" actual
  fixture
  printf '%b' "$pattern" >"$work/caller/.policyignore"
  run_filter >"$work/output" 2>&1 || fail "$label: $(cat "$work/output")"
  actual="$(cd "$work/upstream" && find . -type f -not -path './.git/*' | sed 's|^./||' | sort)"
  [[ "$actual" == "$expected" ]] || fail "$label: expected [$expected], got [$actual]"
  [[ "$(cat "$work/caller/target/sentinel")" == 'preserve me' ]] || fail "$label changed the target"
  echo "ok: $label"
}
refuses_config() {
  local label="$1"
  if run_filter >"$work/output" 2>&1; then fail "$label accepted unsafe input"; fi
  [[ -f "$work/upstream/root.yaml" && -f "$work/upstream/other/drop.yaml" ]] || fail "$label mutated policies before validating input"
  [[ "$(cat "$work/caller/target/sentinel")" == 'preserve me' ]] || fail "$label changed the target"
  echo "ok: $label fails before changes"
}

fixture
refuses_config 'missing policyignore'
fixture
mkdir "$work/caller/.policyignore"
refuses_config 'directory policyignore'
fixture
printf '*\n' >"$work/caller/.policyignore"
chmod 000 "$work/caller/.policyignore"
refuses_config 'unreadable policyignore'
chmod 600 "$work/caller/.policyignore"

all=$'deep/other/drop.yaml\ndirectory\nother/drop.yaml\nother/keep.yaml\nother/nested/keep.yaml\nroot.yaml'
case_keeps 'explicit empty configuration includes everything' '' "$all"
case_keeps 'reinclude below excluded parent' 'other*\n!other/keep.yaml\n' $'directory\nother/keep.yaml\nroot.yaml'
case_keeps 'later exclude overrides reinclude' '*\n!other/keep.yaml\nother/keep.yaml\n' ''
case_keeps 'basename patterns match at every depth' 'drop.yaml\n' $'directory\nother/keep.yaml\nother/nested/keep.yaml\nroot.yaml'
case_keeps 'root anchoring excludes only the root path' '/other/\n' $'deep/other/drop.yaml\ndirectory\nroot.yaml'
case_keeps 'directory patterns do not exclude a regular file' 'directory/\n' "$all"
case_keeps 'ordinary star does not cross a separator' '*\n!other/*.yaml\n' $'other/drop.yaml\nother/keep.yaml'
case_keeps 'double star spans zero or multiple directories' '*\n!other/**/keep.yaml\n' $'other/keep.yaml\nother/nested/keep.yaml'
case_keeps 'anchored literal reinclude' '*\n!/other/keep.yaml\n' 'other/keep.yaml'
case_keeps 'basename literal reinclude' '*\n!keep.yaml\n' $'other/keep.yaml\nother/nested/keep.yaml'
case_keeps 'CRLF and final unterminated reinclude' '*\r\n!/other/keep.yaml' 'other/keep.yaml'
case_keeps 'unescaped trailing spaces are ignored' 'drop.yaml   \n' $'directory\nother/keep.yaml\nother/nested/keep.yaml\nroot.yaml'

fixture
for file in '#literal.yaml' '!literal.yaml' 'star*.yaml' 'space .yaml' 'trailing '; do
  printf '%s\n' "$file" >"$work/upstream/$file"
  git -C "$work/upstream" add -- "$file"
done
printf '%s\n' '*' '!#literal.yaml' '!!literal.yaml' '!star\*.yaml' '!space\ .yaml' '!trailing\ ' >"$work/caller/.policyignore"
run_filter >"$work/output" 2>&1 || fail "escaped literal reinclusions: $(cat "$work/output")"
for file in '#literal.yaml' '!literal.yaml' 'star*.yaml' 'space .yaml' 'trailing '; do
  [[ -f "$work/upstream/$file" ]] || fail "escaped literal was lost: $file"
done
[[ ! -f "$work/upstream/root.yaml" ]] || fail 'escaped rules accidentally included other policies'
echo 'ok: comment, negation, wildcard and whitespace escapes keep literal files'

fixture
printf '%s\n' '*' '!other/keep.yaml' >"$work/caller/.policyignore"
(cd "$work/caller" && RUNNER_TEMP="$work/runner" KYVERNO_POLICIES_TEMP_DIR="$work/upstream" bash -e "$work/verify-allowlist.sh")
printf '!root.yaml\n' >"$work/caller/.policyignore"
(cd "$work/caller" && RUNNER_TEMP="$work/runner" KYVERNO_POLICIES_TEMP_DIR="$work/upstream" bash -e "$work/filter-policies.sh")
[[ -f "$work/upstream/other/keep.yaml" && ! -f "$work/upstream/root.yaml" ]] || fail 'filter reread configuration after validation'
echo 'ok: filtering consumes the validated snapshot'

# Failure injection reaches the real executable boundaries, never a copied matcher.
fixture
printf '*\n' >"$work/caller/.policyignore"
mkdir -p "$work/bin"
for command in cat find git; do
  printf '#!/usr/bin/env bash\nexit 23\n' >"$work/bin/$command"
  chmod +x "$work/bin/$command"
  if (
    export PATH="$work/bin:$PATH"
    run_filter
  ) >"$work/output" 2>&1; then
    fail "failed $command read was accepted"
  fi
  [[ -f "$work/upstream/root.yaml" ]] || fail "failed $command read removed policies"
  rm "$work/bin/$command"
  echo "ok: failed $command read is rejected"
done
