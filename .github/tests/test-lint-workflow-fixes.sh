#!/usr/bin/env bash
# shellcheck disable=SC2016 # Match literal GitHub expressions and shell source.

# Run each consumer's actual patch exporter against real Git changes. Workflow edits
# must remain downloadable without reaching a contents-only signing job, and a mixed
# patch must stay intact (a rename or related edit cannot be committed in pieces).
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

for workflow in validate-go-project:tidy validate-go-project:golangci-lint validate-go-project:lint; do
  job="${workflow#*:}"
  file="$root/.github/workflows/${workflow%:*}.yaml"
  prepare="$(JOB="$job" yq -o=json '.jobs[strenv(JOB)].steps[] | select(.id == "fixes")' "$file")"
  composite="$(jq -r '.uses // ""' <<< "$prepare")"
  mode=ordinary
  if [[ -n "$composite" ]]; then
    [[ "$composite" == '$/.github/actions/prepare-fixes' ]] || fail 'unknown exporter'
    action="$root/.github/actions/prepare-fixes/action.yaml"
    yq -er '.runs.steps[] | select(.id == "prepare") | .run' "$action" >"$work/export.sh"
    mode="$(jq -r '.with.mode // "ordinary"' <<< "$prepare")"
    [[ "$(yq -r '.runs.steps[] | select(.id == "prepare") | .working-directory' "$action")" == '${{ github.workspace }}' ]] || fail 'composite must export from repository root'
  else
    jq -er '.run' <<< "$prepare" >"$work/export.sh"
  fi
  for enabled in false true; do
  for scenario in workflow clean ordinary untracked new-workflow deleted-workflow mixed rename-in rename-out similar-directory nested-workflow binary-only binary-mixed mode-only mode-mixed diff-noprefix diff-prefix diff-textconv diff-external diff-color; do
    fixture="$work/$workflow-$enabled-$scenario"
    mkdir -p "$fixture/.github/workflows" "$fixture/.github/workflows-extra" "$fixture/nested/.github/workflows" "$fixture/nested/module" "$fixture/../artifacts-$workflow-$enabled-$scenario"
    git -C "$fixture" init -q
    git -C "$fixture" config user.name test
    git -C "$fixture" config user.email test@example.invalid
    git -C "$fixture" config commit.gpgsign false
    git -C "$fixture" config core.filemode true
    printf 'original\n' >"$fixture/.github/workflows/ci.yaml"
    printf 'original\n' >"$fixture/value.txt"
    mkdir "$fixture/sub"
    printf 'original\n' >"$fixture/sub/value.txt"
    printf 'original\n' >"$fixture/.github/workflows-extra/value.yaml"
    printf 'original\n' >"$fixture/nested/.github/workflows/ci.yaml"
    printf 'before\000binary\n' >"$fixture/payload.bin"
    printf '#!/bin/sh\necho fixture\n' >"$fixture/script.sh"
    git -C "$fixture" add -- .github value.txt sub nested payload.bin script.sh
    git -C "$fixture" commit -qm base

    changed=true
    manual=true
    case "$scenario" in
      clean) changed=false; manual=false ;;
      ordinary) printf 'formatted\n' >"$fixture/value.txt"; manual=false ;;
      untracked) printf 'new\n' >"$fixture/nested/new file.txt"; manual=false ;;
      workflow) printf 'formatted\n' >"$fixture/.github/workflows/ci.yaml" ;;
      new-workflow) printf 'new\n' >"$fixture/.github/workflows/new workflow.yml" ;;
      deleted-workflow) rm "$fixture/.github/workflows/ci.yaml" ;;
      mixed)
        printf 'formatted\n' >"$fixture/.github/workflows/ci.yaml"
        printf 'formatted\n' >"$fixture/value.txt"
        printf 'new\n' >"$fixture/nested/new file.txt"
        ;;
      rename-in) mv "$fixture/value.txt" "$fixture/.github/workflows/renamed.yml" ;;
      rename-out) mv "$fixture/.github/workflows/ci.yaml" "$fixture/moved.txt" ;;
      similar-directory) printf 'formatted\n' >"$fixture/.github/workflows-extra/value.yaml"; manual=false ;;
      nested-workflow) printf 'formatted\n' >"$fixture/nested/.github/workflows/ci.yaml"; manual=false ;;
      binary-only) printf 'after\000binary\n' >"$fixture/payload.bin"; manual=false ;;
      binary-mixed)
        printf 'after\000binary\n' >"$fixture/payload.bin"
        printf 'formatted\n' >"$fixture/.github/workflows/ci.yaml"
        ;;
      mode-only) chmod +x "$fixture/script.sh"; manual=false ;;
      mode-mixed)
        chmod +x "$fixture/script.sh"
        printf 'formatted\n' >"$fixture/.github/workflows/ci.yaml"
        ;;
      diff-*)
        # Identical root/sub files make a prefixless patch apply successfully
        # to the wrong file unless the exporter explicitly controls its format.
        printf 'formatted\n' >"$fixture/sub/value.txt"
        manual=false
        case "$scenario" in
          diff-noprefix) git -C "$fixture" config diff.noprefix true ;;
          diff-prefix)
            git -C "$fixture" config diff.srcPrefix before/
            git -C "$fixture" config diff.dstPrefix after/
            ;;
          diff-textconv)
            printf 'sub/value.txt diff=display\n' >"$fixture/.git/info/attributes"
            printf '#!/bin/sh\nsed '\''s/^/display: /'\'' "$1"\n' >"$fixture/.git/display"
            chmod +x "$fixture/.git/display"
            git -C "$fixture" config diff.display.textconv "$fixture/.git/display"
            ;;
          diff-external)
            printf '#!/bin/sh\nexit 0\n' >"$fixture/.git/display"
            chmod +x "$fixture/.git/display"
            git -C "$fixture" config diff.external "$fixture/.git/display"
            ;;
          diff-color)
            git -C "$fixture" config color.ui always
            git -C "$fixture" config color.diff always
            ;;
        esac
        ;;
    esac
    [[ "$enabled" == true ]] || manual=false
    [[ "$job" == lint ]] || manual=false

    action_path="$root/.github/actions/prepare-fixes"
    if [[ -n "$composite" ]]; then
      action_path="$fixture/.devantler-tech-actions/.github/actions/prepare-fixes"
      mkdir -p "$action_path"
      cp "$action" "$action_path/action.yaml"
    fi

    artifacts="$fixture/../artifacts-$workflow-$enabled-$scenario"
    (
      cd "$fixture"
      export FIXES_ARTIFACT=megalinter-fixes-123 RUNNER_TEMP="$artifacts" GITHUB_OUTPUT="$artifacts/outputs"
      export MANUAL_WORKFLOW_FIXES="$enabled"
      export ACTION_PATH="$action_path" PREPARE_MODE="$mode" GITHUB_WORKSPACE="$fixture"
      bash -euo pipefail "$work/export.sh"
    ) >"$artifacts/log" 2>&1 || fail "$workflow/$scenario exporter failed"
    grep -qxF "changed=$changed" "$artifacts/outputs" || fail "$workflow/$scenario changed output"
    if [[ "$job" == lint ]]; then
      grep -qxF "manual-required=$manual" "$artifacts/outputs" || fail "$workflow/$scenario manual routing"
    fi
    grep -qxF 'artifact-name=megalinter-fixes-123' "$artifacts/outputs" || fail "$workflow/$scenario artifact identity"
    [[ ! -d "$fixture/.devantler-tech-actions" ]] || fail "$workflow/$scenario leaked its source checkout"
    if [[ "$manual" == true ]]; then
      grep -qF '::warning::' "$artifacts/log" || fail "$workflow/$scenario needs an actionable warning"
      grep -qF 'git apply' "$artifacts/log" || fail "$workflow/$scenario warning must explain recovery"
    elif grep -qF '::warning::' "$artifacts/log"; then
      fail "$workflow/$enabled/$scenario emitted an unsolicited manual-routing warning"
    fi
    patch="$artifacts/megalinter-fixes-123.patch"
    if [[ "$changed" == true ]]; then
      [[ -s "$patch" ]] || fail "$workflow/$scenario lost the patch"
      # Stage the fixture's intended result only AFTER export, so additions above really
      # are untracked when the production exporter sees them.
      git -C "$fixture" add -- .github sub nested payload.bin script.sh
      [[ ! -e "$fixture/value.txt" ]] || git -C "$fixture" add -- value.txt
      [[ ! -e "$fixture/moved.txt" ]] || git -C "$fixture" add -- moved.txt
      expected="$(git -C "$fixture" write-tree)"
      # Transfer only committed objects. A local clone also copies unreachable
      # blobs staged above, which could let git apply recover omitted binary
      # payloads from the fixture's object store instead of from the artifact.
      git clone -q --no-local "$fixture" "$artifacts/replay"
      git -C "$artifacts/replay" apply --index "$patch" || fail "$workflow/$scenario patch cannot be applied"
      [[ "$(git -C "$artifacts/replay" write-tree)" == "$expected" ]] || fail "$workflow/$scenario exported only part of the fix"
    else
      [[ ! -s "$patch" ]] || fail "$workflow/$scenario created a patch for a clean tree"
    fi
    echo "PASS: $workflow/$enabled/$scenario"
  done
  done

  # The job output is the authorization handed to the existing signer. Require an
  # explicit false manual flag so a missing exporter output cannot authorize a commit.
  if [[ "$job" == lint ]]; then
  output="$(yq -r '.jobs.lint.outputs."fixes-created"' "$file")"
  [[ "$output" == "\${{ steps.fixes.outputs.changed == 'true' && steps.fixes.outputs.manual-required == 'false' }}" ]] ||
    fail "$workflow must withhold workflow patches from the signer"

  # Every changed patch, including a manual one, must still use the upload path. The
  # existing contract test covers the Go caller's full opt-in/fork/bot boundary.
  if [[ -n "$composite" ]]; then
    upload_if="$(yq -r '.runs.steps[] | select(.uses != null and (.uses | test("^actions/upload-artifact@"))) | .if' "$action")"
    upload_if="${upload_if//steps.prepare/steps.fixes}"
  else
    upload_if="$(yq -r '.jobs.lint.steps[] | select(.uses != null and (.uses | test("^actions/upload-artifact@"))) | .if' "$file")"
  fi
  [[ "$upload_if" == *"steps.fixes.outputs.changed == 'true'"* && "$upload_if" != *manual-required* ]] ||
    fail "$workflow must retain manual patches for download"
  fi

  # A failed git read must not be mistaken for a clean or signable patch.
  mkdir -p "$work/not-a-repo-$workflow"
  if (cd "$work/not-a-repo-$workflow" && ACTION_PATH="$root/.github/actions/prepare-fixes" PREPARE_MODE="$mode" FIXES_ARTIFACT=x RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/error-output" bash -euo pipefail "$work/export.sh") >/dev/null 2>&1; then
    fail "$workflow accepted a Git failure"
  fi
done

# Exercise the hosted failure fixture itself, so a change to Git's raw-output
# options cannot silently stop injecting the late read failure. The wrapper must
# still allow exporting the complete patch before rejecting workflow inspection.
fixture="$work/hosted-failure"
mkdir -p "$fixture" "$work/hosted-temp"
: >"$work/hosted-path"
(
  cd "$fixture"
  SCENARIO=export-failure MANUAL=true RUNNER_TEMP="$work/hosted-temp" \
    GITHUB_PATH="$work/hosted-path" bash "$root/.github/tests/fixtures/prepare-fixes-runner.sh" setup
)
rc=0
(
  cd "$fixture"
  RUNNER_TEMP="$work/hosted-temp" PATH="$work/hosted-temp/git-wrapper:$PATH" \
    git diff --no-ext-diff --no-textconv --name-only --no-renames HEAD -- .github/workflows/
) >"$work/hosted-inspection.log" 2>&1 || rc=$?
[[ "$rc" == 42 ]] || fail 'hosted workflow inspection fault was not injected'
(
  cd "$fixture"
  RUNNER_TEMP="$work/hosted-temp" PATH="$work/hosted-temp/git-wrapper:$PATH" \
    git diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --binary --full-index HEAD
) >"$work/hosted-patch"
[[ -s "$work/hosted-patch" ]] || fail 'hosted wrapper refused raw patch export'

echo 'PASS: workflow fixes stay complete, recoverable, and out of automatic commits'

# Exercise the actual hosted setup with a native exporter outside the consumer.
# Removing only cleanup must reproduce a false dirty result and a helper gitlink.
yq -r '.jobs.test-prepare-fixes.steps[] | select(.name == "📦 Create disposable consumer") | .run' \
  "$root/.github/workflows/ci.yaml" >"$work/native-hosted-setup.sh"
yq -r '.runs.steps[] | select(.id == "prepare") | .run' "$action" >"$work/native-hosted-export.sh"
for ablated in false true; do
  native_case="$work/native-hosted-$ablated"
  consumer="$native_case/consumer"
  helper="$consumer/.devantler-tech-actions"
  mkdir -p "$helper/.github/tests/fixtures" "$native_case/runner"
  cp "$root/.github/tests/fixtures/prepare-fixes-runner.sh" "$helper/.github/tests/fixtures/prepare-fixes-runner.sh"
  git -C "$helper" init -q
  git -C "$helper" config user.name 'Native exporter fixture'
  git -C "$helper" config user.email 'fixture@example.invalid'
  git -C "$helper" config commit.gpgsign false
  git -C "$helper" add -- .github/tests/fixtures/prepare-fixes-runner.sh
  git -C "$helper" commit -qm 'fixture source'
  cp "$work/native-hosted-setup.sh" "$native_case/setup.sh"
  if [[ "$ablated" == true ]]; then
    sed '/rm -rf -- .devantler-tech-actions/d' "$native_case/setup.sh" >"$native_case/without-cleanup.sh"
    cmp -s "$native_case/setup.sh" "$native_case/without-cleanup.sh" && fail 'hosted cleanup ablation changed nothing'
    cp "$native_case/without-cleanup.sh" "$native_case/setup.sh"
  fi
  (
    cd "$consumer"
    env RUNNER_TEMP="$native_case/runner" SCENARIO=clean MANUAL=false bash "$native_case/setup.sh"
    env RUNNER_TEMP="$native_case/runner" ACTION_PATH="$root/.github/actions/prepare-fixes" \
      GITHUB_WORKSPACE="$consumer" FIXES_ARTIFACT=native-fixes PREPARE_MODE=ordinary \
      MANUAL_WORKFLOW_FIXES=false GITHUB_OUTPUT="$native_case/outputs" \
      bash -euo pipefail "$work/native-hosted-export.sh"
  ) >"$native_case/log" 2>&1 || fail 'native hosted setup/export failed'
  if [[ "$ablated" == true ]]; then
    grep -Fxq 'changed=true' "$native_case/outputs" || fail 'missing cleanup did not reproduce a false dirty result'
    grep -Fq '.devantler-tech-actions' "$native_case/runner/native-fixes.patch" || fail 'missing cleanup did not expose the helper in the patch'
  else
    [[ ! -e "$helper" ]] || fail 'hosted setup retained its helper checkout'
    grep -Fxq 'changed=false' "$native_case/outputs" || fail 'native exporter reports a clean consumer as changed'
    [[ ! -s "$native_case/runner/native-fixes.patch" ]] || fail 'clean native exporter produced a patch'
  fi
  echo "PASS: native hosted exporter; cleanup ablated=$ablated"
done

# Exercise the hosted verify phase against a stubbed artifact listing. A failed
# assertion must name the check with its expected and actual values, and a
# listing that has not caught up yet must be re-read, without relaxing the exact
# count: a missing or extra artifact still fails.
runner_fixture="$root/.github/tests/fixtures/prepare-fixes-runner.sh"
mkdir -p "$work/verify-bin"
cat >"$work/verify-bin/gh" <<'GH'
#!/usr/bin/env bash
# Answer each artifact listing with the next count from VERIFY_COUNTS.
calls=$(( $(cat "$VERIFY_STATE/calls" 2>/dev/null || echo 0) + 1 ))
echo "$calls" >"$VERIFY_STATE/calls"
read -r -a counts <<<"$VERIFY_COUNTS"
index=$(( calls <= ${#counts[@]} ? calls - 1 : ${#counts[@]} - 1 ))
jq -n --arg name "$ARTIFACT" --argjson n "${counts[$index]}" \
  '{artifacts: ([range($n) | {name: $name}] + [{name: "unrelated"}])}'
GH
chmod +x "$work/verify-bin/gh"

# Run verify for one hosted scenario. Remaining arguments are NAME=value overrides
# of the step outputs. Upload scenarios get a real patch in both transfer paths.
run_verify() {
  local name="$1" scenario="$2" upload="$3" counts="$4"
  shift 4
  local case_dir="$work/verify-$name"
  mkdir -p "$case_dir/consumer" "$case_dir/runner/download" "$case_dir/state"
  local artifact="prepare-fixes-test-$name"
  (
    cd "$case_dir/consumer"
    SCENARIO="$scenario" MANUAL=false RUNNER_TEMP="$case_dir/runner" GITHUB_PATH="$case_dir/path" \
      bash "$runner_fixture" setup >/dev/null
    if [[ "$upload" == true && "$scenario" != clean ]]; then
      git add -- notes.txt new-file.txt binary.bin executable.sh
      git diff --cached --no-color --binary --full-index HEAD >"$case_dir/runner/$artifact.patch"
      cp "$case_dir/runner/$artifact.patch" "$case_dir/runner/download/$artifact.patch"
    fi
  )
  local changed=true
  [[ "$scenario" != clean ]] || changed=false
  (
    cd "$case_dir/consumer"
    env PATH="$work/verify-bin:$PATH" VERIFY_STATE="$case_dir/state" VERIFY_COUNTS="$counts" \
      SCENARIO="$scenario" MANUAL=false UPLOAD="$upload" ARTIFACT="$artifact" \
      RUNNER_TEMP="$case_dir/runner" GITHUB_REPOSITORY=example/fixture GITHUB_RUN_ID=1 \
      FIXTURE_ARTIFACT_LIST_DELAY=0 \
      ACTUAL_ARTIFACT="$artifact" ACTUAL_ELIGIBLE="$upload" ACTUAL_CHANGED="$changed" \
      ACTUAL_OUTCOME=success ACTUAL_MANUAL=false "$@" \
      bash "$runner_fixture" verify
  ) >"$case_dir/log" 2>&1
}
verify_calls() { cat "$work/verify-$1/state/calls" 2>/dev/null || echo 0; }

run_verify pass ordinary true 1 || fail "verify rejected a correct upload: $(cat "$work/verify-pass/log")"
grep -Fq 'artifact count=1' "$work/verify-pass/log" || fail 'verify did not report the artifact count'

run_verify lagging ordinary true '0 0 1' ||
  fail "verify did not re-read a listing that had not caught up: $(cat "$work/verify-lagging/log")"
[[ "$(verify_calls lagging)" == 3 ]] || fail "lagging listing read $(verify_calls lagging) times, want 3"

if run_verify missing ordinary true 0; then fail 'verify accepted a missing artifact'; fi
grep -Fq 'artifact count: expected 1, got 0' "$work/verify-missing/log" ||
  fail "missing artifact did not name the count: $(cat "$work/verify-missing/log")"
[[ "$(verify_calls missing)" -gt 1 ]] || fail 'missing artifact was not re-read before failing'

if run_verify extra ordinary true 2; then fail 'verify accepted an extra artifact'; fi
grep -Fq 'artifact count: expected 1, got 2' "$work/verify-extra/log" ||
  fail "extra artifact did not name the count: $(cat "$work/verify-extra/log")"
[[ "$(verify_calls extra)" == 1 ]] || fail 'an extra artifact must fail without waiting'

run_verify absent read-only false 0 || fail "verify rejected a suppressed upload: $(cat "$work/verify-absent/log")"
if run_verify unexpected read-only false 1; then fail 'verify accepted an artifact from a suppressed upload'; fi
grep -Fq 'artifact count: expected 0, got 1' "$work/verify-unexpected/log" ||
  fail "unexpected artifact did not name the count: $(cat "$work/verify-unexpected/log")"

if run_verify outcome clean true 0 ACTUAL_OUTCOME=failure; then fail 'verify accepted a failed step'; fi
grep -Fq 'step outcome: expected success, got failure' "$work/verify-outcome/log" ||
  fail "failed step did not name the outcome: $(cat "$work/verify-outcome/log")"

if run_verify name clean true 0 ACTUAL_ARTIFACT=; then fail 'verify accepted a missing artifact name'; fi
grep -Fq 'artifact name: expected prepare-fixes-test-name, got <empty>' "$work/verify-name/log" ||
  fail "missing artifact name was not reported: $(cat "$work/verify-name/log")"

echo 'PASS: hosted verify names failed checks and re-reads a lagging artifact listing'
