#!/usr/bin/env bash
# GitHub runner integration fixture, copied outside the helper before it is removed.
set -euo pipefail
case "$1" in
  setup)
    git init --quiet
    git config user.name 'Fix exporter fixture'
    git config user.email 'fixture@example.invalid'
    git config commit.gpgsign false
    mkdir -p module .github/workflows
    printf 'before\n' > notes.txt
    printf 'module example.invalid/fixture\n' > module/go.mod
    printf 'name: Before\n' > .github/workflows/fixture.yaml
    git add -- notes.txt module .github/workflows/fixture.yaml
    git commit --quiet -m 'fixture base'
    git clone --quiet --no-local . "$RUNNER_TEMP/replay"
    if [ "$SCENARIO" != clean ]; then
      printf 'after\n' > notes.txt
      printf 'outside the nested Go module\n' > new-file.txt
      printf '\000\001\377' > binary.bin
      printf '#!/bin/sh\nexit 0\n' > executable.sh
      chmod +x executable.sh
      if [ "$MANUAL" = true ]; then
        printf 'name: After\n' > .github/workflows/fixture.yaml
      fi
      git add -- notes.txt new-file.txt binary.bin executable.sh .github/workflows/fixture.yaml
    fi
    git write-tree > "$RUNNER_TEMP/expected-tree"
    git read-tree HEAD
    if [ "$SCENARIO" = export-failure ]; then
      # Fail a late command after changed=true. The real inline action must
      # remain failed while preserving its opted-in complete manual patch.
      mkdir -p "$RUNNER_TEMP/git-wrapper"
      command -v git > "$RUNNER_TEMP/real-git"
      cat > "$RUNNER_TEMP/git-wrapper/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'diff --no-ext-diff --no-textconv --name-only --no-renames HEAD -- .github/workflows/' ]; then
  echo 'intentional fixture workflow inspection failure' >&2
  exit 42
fi
exec "$(cat "$RUNNER_TEMP/real-git")" "$@"
GIT
      chmod +x "$RUNNER_TEMP/git-wrapper/git"
      echo "$RUNNER_TEMP/git-wrapper" >> "$GITHUB_PATH"
    fi
    ;;
  verify)
    # Name every failed check with its expected and actual values: a bare test
    # under errexit only reports "exit code 1".
    expect() {
      if [ "$2" != "$3" ]; then
        printf 'FAIL hosted fix exporter (%s): %s: expected %s, got %s\n' \
          "$SCENARIO" "$1" "${2:-<empty>}" "${3:-<empty>}" >&2
        exit 1
      fi
    }
    helper=absent
    [ ! -e .devantler-tech-actions ] || helper=present
    expect 'helper checkout' absent "$helper"
    expect 'artifact name' "$ARTIFACT" "$ACTUAL_ARTIFACT"
    expect 'upload eligibility' "$UPLOAD" "$ACTUAL_ELIGIBLE"
    expected_changed=true
    [ "$SCENARIO" != clean ] || expected_changed=false
    expect 'changed output' "$expected_changed" "$ACTUAL_CHANGED"
    if [ "$SCENARIO" = export-failure ]; then
      expect 'step outcome' failure "$ACTUAL_OUTCOME"
      expect 'manual-required output' '' "$ACTUAL_MANUAL"
    else
      expect 'step outcome' success "$ACTUAL_OUTCOME"
      expect 'manual-required output' "$MANUAL" "$ACTUAL_MANUAL"
    fi
    expected_artifacts=0
    if [ "$UPLOAD" = true ] && [ "$expected_changed" = true ]; then
      expected_artifacts=1
      cmp "$RUNNER_TEMP/$ARTIFACT.patch" "$RUNNER_TEMP/download/$ARTIFACT.patch"
      git -C "$RUNNER_TEMP/replay" apply --index "$RUNNER_TEMP/download/$ARTIFACT.patch"
      expect 'replayed tree' "$(cat "$RUNNER_TEMP/expected-tree")" "$(git -C "$RUNNER_TEMP/replay" write-tree)"
    fi
    # Check real artifact absence as well as successful transfers. A skipped
    # download alone cannot establish that the upload was suppressed. The run's
    # artifact listing can lag a finished upload by a few seconds, so re-read it
    # (bounded) while it shows fewer than expected; the count must still match
    # exactly, so a missing or extra artifact fails.
    list_artifacts() {
      gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" --paginate > "$RUNNER_TEMP/artifacts.json"
    }
    count_artifacts() {
      jq -s --arg name "$ARTIFACT" '[.[].artifacts[] | select(.name == $name)] | length' "$RUNNER_TEMP/artifacts.json"
    }
    attempts=6
    delay="${FIXTURE_ARTIFACT_LIST_DELAY:-5}"
    attempt=1
    list_artifacts
    count="$(count_artifacts)"
    while [ "$count" -lt "$expected_artifacts" ] && [ "$attempt" -lt "$attempts" ]; do
      sleep "$delay"
      attempt=$((attempt + 1))
      list_artifacts
      count="$(count_artifacts)"
    done
    expect 'artifact count' "$expected_artifacts" "$count"
    printf 'PASS hosted fix exporter: %s; artifact count=%s; outcome=%s\n' "$SCENARIO" "$count" "$ACTUAL_OUTCOME"
    ;;
  *) echo 'unknown fixture phase' >&2; exit 1 ;;
esac
