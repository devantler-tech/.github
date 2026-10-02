#!/usr/bin/env bash
# Execute the shipped copy step against successful, deliberately empty and failing fixtures and
# check the destination after each one (#356). A failure anywhere must leave the previous policies
# exactly as they were, and must never be reported as success.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/sync-cluster-policies.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step="$work/copy-policies.sh"
yq -r '.jobs.sync-policies.steps[] | select(.id == "copy-policies") | .run' "$workflow" >"$step"
[[ -s "$step" && "$(cat "$step")" != null ]] || fail "no copy-policies step found in $workflow"

real_cp="$(command -v cp)"
real_mv="$(command -v mv)"

# Upstream after filtering: three selected entries plus the clone's own .git directory.
fixture() {
  rm -rf "${work:?}/caller" "${work:?}/upstream" "${work:?}/runner" "${work:?}/bin" "${work:?}/calls"
  mkdir -p "$work/caller/target/old" "$work/upstream/.git" "$work/upstream/best/nested" "$work/runner" "$work/bin"
  printf 'old root\n' >"$work/caller/target/root.yaml"
  printf 'stale\n' >"$work/caller/target/old/stale.yaml"
  printf 'kept\n' >"$work/caller/target/.keep"
  printf '[core]\n' >"$work/upstream/.git/config"
  printf 'new root\n' >"$work/upstream/root.yaml"
  printf 'a\n' >"$work/upstream/best/a.yaml"
  printf 'b\n' >"$work/upstream/best/nested/b.yaml"
  printf '%s\0' ./root.yaml ./best/a.yaml ./best/nested/b.yaml >"$work/runner/policy-files"
  : >"$work/runner/policy-exclusions"
}
# Leave only the clone's .git behind, as the filter does when every file is excluded.
empty_selection() {
  rm -rf "$work/upstream/root.yaml" "$work/upstream/best"
}
snapshot() {
  (
    cd "$1"
    find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -f "$path" ]]; then printf '%s %s\n' "$path" "$(cksum <"$path")"; else printf '%s/\n' "$path"; fi
    done
  )
}
run_step() {
  (
    cd "$work/caller"
    export PATH="$work/bin:$PATH" KYVERNO_POLICIES_DIR=target \
      KYVERNO_POLICIES_TEMP_DIR="$work/upstream" RUNNER_TEMP="$work/runner"
    bash -e "$step"
  ) >"$work/output" 2>&1
}
no_leftovers() {
  local left
  left="$(cd "$work/caller" && find . -maxdepth 1 \( -name 'target.sync.*' -o -name 'target.previous.*' \) -print)"
  [[ -z "$left" ]] || fail "$1 left staging directories behind: $left"
}
# The step must fail, name the failure, and leave the previous destination byte-for-byte unchanged.
refuses() {
  local label="$1" message="$2" before
  before="$(snapshot "$work/caller/target")"
  if run_step; then fail "$label was reported as success: $(cat "$work/output")"; fi
  grep -q "::error::.*$message" "$work/output" || fail "$label did not report '$message': $(cat "$work/output")"
  [[ "$(snapshot "$work/caller/target")" == "$before" ]] || fail "$label changed the destination"
  no_leftovers "$label"
  echo "ok: $label fails and keeps the previous policies"
}
# Fail the Nth mv (1 = setting the previous policies aside, 2 = moving the selection in). With
# partial set, the failing call still moves its first source, as an interrupted mv would.
mv_shim() {
  cat >"$work/bin/mv" <<EOF
#!/usr/bin/env bash
set -eu
call=\$((\$(cat "$work/calls" 2>/dev/null || echo 0) + 1))
echo "\$call" >"$work/calls"
if [[ "\$call" -ne $1 ]]; then exec "$real_mv" "\$@"; fi
[[ "\$1" == -- ]] && shift
if [[ "$2" == partial ]]; then "$real_mv" -- "\$1" "\${@: -1}"; fi
exit 23
EOF
  chmod +x "$work/bin/mv"
}

expected=$'./.keep '"$(printf 'kept\n' | cksum)"$'\n./best/\n./best/a.yaml '"$(printf 'a\n' | cksum)"$'\n./best/nested/\n./best/nested/b.yaml '"$(printf 'b\n' | cksum)"$'\n./root.yaml '"$(printf 'new root\n' | cksum)"

fixture
run_step || fail "successful sync failed: $(cat "$work/output")"
[[ "$(snapshot "$work/caller/target")" == "$expected" ]] ||
  fail "successful sync produced [$(snapshot "$work/caller/target")], expected [$expected]"
no_leftovers 'successful sync'
echo 'ok: a successful sync replaces the policies, keeps dot entries and leaves nothing behind'

fixture
mkdir -p "$work/caller/fresh-parent"
(
  cd "$work/caller"
  KYVERNO_POLICIES_DIR=fresh-parent/target/ KYVERNO_POLICIES_TEMP_DIR="$work/upstream" RUNNER_TEMP="$work/runner" bash -e "$step"
) >"$work/output" 2>&1 || fail "sync into a new directory failed: $(cat "$work/output")"
[[ -f "$work/caller/fresh-parent/target/best/nested/b.yaml" ]] || fail 'sync into a new directory copied nothing'
echo 'ok: a missing destination with a trailing slash is created and filled'

fixture
empty_selection
printf '%s\0' ./root.yaml ./best/a.yaml ./best/nested/b.yaml >"$work/runner/policy-exclusions"
run_step || fail "deliberately empty selection failed: $(cat "$work/output")"
grep -q '::notice::.*emptied deliberately' "$work/output" || fail "deliberately empty selection was not announced: $(cat "$work/output")"
[[ "$(snapshot "$work/caller/target")" == "./.keep $(printf 'kept\n' | cksum)" ]] ||
  fail "deliberately empty selection left [$(snapshot "$work/caller/target")]"
no_leftovers 'deliberately empty selection'
echo 'ok: a deliberately empty selection empties the policies and says so'

fixture
empty_selection
printf '%s\0' ./root.yaml >"$work/runner/policy-exclusions"
refuses 'an empty selection that .policyignore does not explain' 'excludes only 1 of 3'

fixture
empty_selection
: >"$work/runner/policy-files"
refuses 'an empty upstream' 'excludes only 0 of 0'

fixture
rm "$work/runner/policy-exclusions"
refuses 'a missing validated plan' 'plan policy-exclusions is missing'

fixture
printf '#!/usr/bin/env bash\nexit 23\n' >"$work/bin/cp"
chmod +x "$work/bin/cp"
refuses 'a failed copy' 'copying the selected policies failed'

fixture
cat >"$work/bin/cp" <<EOF
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf x >>"\${@: -1}/root.yaml"
EOF
chmod +x "$work/bin/cp"
refuses 'a copy that differs from the selection' 'staged copy of root.yaml differs'

fixture
mv_shim 1 whole
refuses 'a failure to set the previous policies aside' 'could not set the previous policies aside'

fixture
mv_shim 1 partial
refuses 'an interrupted move of the previous policies' 'could not set the previous policies aside'

fixture
mv_shim 2 whole
refuses 'a failure to move the selection in' 'could not move the verified policies'

fixture
mv_shim 2 partial
refuses 'an interrupted move of the selection' 'could not move the verified policies'
