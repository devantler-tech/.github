#!/usr/bin/env bash
# Preserve distinct, useful compiler caches without replacing either test mode.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
yq -o=json . "$workflow" > "$work/workflow.json"
cat > "$work/cache.jq" <<'JQ'
  all(["test","coverage"][];
    . as $id | $workflow[0].jobs[$id] as $job |
    ($job.steps | map(select(.id == "setup-go"))) as $setup |
    ($job.steps | map(select(.id == "go-build-cache-path"))) as $path |
    ($job.steps | map(select(.id == "go-build-cache"))) as $restore |
    ($job.steps | map(select(.name == "Save Go compilation cache"))) as $save |
    ($job.steps | map(.id // .name)) as $order |
    ($setup|length==1) and ($path|length==1) and ($restore|length==1) and ($save|length==1) and
    ($setup[0].with.cache == true) and
    ($setup[0].if == null and $path[0].if == null and $restore[0].if == null) and
    ($path[0].shell == "bash") and
    ($path[0].run | contains("cache_path=\"$(go env GOCACHE)\"")) and
    ($path[0].run | contains("[[ \"$cache_path\" == /* && \"$cache_path\" != *$'\\n'* ]]")) and
    ($path[0].run | contains("printf 'path=%s\\n' \"$cache_path\" >> \"$GITHUB_OUTPUT\"")) and
    ($restore[0].uses | startswith("actions/cache/restore@")) and
    ($save[0].uses | startswith("actions/cache/save@")) and
    ($restore[0].uses | split("@")[1]) == ($save[0].uses | split("@")[1]) and
    ($restore[0].with.path == "${{ steps.go-build-cache-path.outputs.path }}") and
    ($restore[0].with.key | contains("${{ github.job }}")) and
    ($restore[0].with.key | contains("${{ runner.os }}")) and
    ($restore[0].with.key | contains("${{ runner.arch }}")) and
    ($restore[0].with.key | contains("${{ steps.setup-go.outputs.go-version }}")) and
    ($restore[0].with.key | contains("${{ inputs.working-directory || '.' }}")) and
    ($restore[0].with.key | contains("hashFiles(format('{0}/go.mod', inputs.working-directory || '.'), format('{0}/go.sum', inputs.working-directory || '.'))")) and
    ($restore[0].with["restore-keys"] == null) and
    ($save[0].with.path == $restore[0].with.path) and
    ($save[0].with.key == "${{ steps.go-build-cache.outputs.cache-primary-key }}") and
    ($save[0].if == "success() && steps.go-build-cache.outputs.cache-hit != 'true'") and
    ([$setup[0],$path[0],$restore[0],$save[0]] | all(."continue-on-error" == null or ."continue-on-error" == false)) and
    ([ $job.steps[] | select(.name == "🧪 Test" or .name == "📄 Generate coverage") ] | length == 1) and
    ([ $job.steps[] | select(.name == "🧪 Test" or .name == "📄 Generate coverage") ] | all(.if == null and (."continue-on-error" == null or ."continue-on-error" == false))) and
    (($order|index("setup-go")) < ($order|index("go-build-cache-path"))) and
    (($order|index("go-build-cache-path")) < ($order|index("go-build-cache"))) and
    (($order|index("go-build-cache")) < ($order|index(if $id == "test" then "🧪 Test" else "📄 Generate coverage" end))) and
    (($order|index(if $id == "test" then "🧪 Test" else "📄 Generate coverage" end)) < ($order|index("Save Go compilation cache")))
  )
JQ
check_contract() {
  jq -en --slurpfile workflow "$1" -f "$work/cache.jq" > /dev/null &&
    bash "$root/.github/tests/go-disk-step-contract.sh" "$1"
}
if ! check_contract "$work/workflow.json"; then
  echo 'FAIL: both test modes need distinct compiler cache identities, restore-before-test and save-after-success' >&2
  exit 1
fi
for mutation in \
  '.jobs.test.steps |= map(select(.name != "Save Go compilation cache"))' \
  '(.jobs.coverage.steps[] | select(.id == "go-build-cache") | .with.key) = "shared"' \
  '(.jobs.test.steps[] | select(.id == "go-build-cache") | .with.key) |= sub("\\$\\{\\{ steps.setup-go.outputs.go-version \\}\\}"; "unpinned")' \
  '(.jobs.coverage.steps[] | select(.id == "go-build-cache") | .with.key) |= sub("go.sum"; "go.mod")' \
  '(.jobs.test.steps[] | select(.id == "go-build-cache") | .with["restore-keys"]) = "go-build-v1-"' \
  '(.jobs.test.steps[] | select(.name == "Save Go compilation cache") | .if) = "always()"' \
  '(.jobs.coverage.steps[] | select(.name == "Save Go compilation cache") | .with.path) = "~/go"' \
  '(.jobs.test.steps[] | select(.id == "go-build-cache-path") | .run) = "echo path=/tmp"' \
  '.jobs.test.steps |= (map(select(.name == "Save Go compilation cache")) + map(select(.name != "Save Go compilation cache")))' \
  '(.jobs.test.steps[] | select(.name == "🧪 Test") | .if) = "false"' \
  '(.jobs.coverage.steps[] | select(.name == "📄 Generate coverage") | .run) = "go test ./..."'; do
  jq "$mutation" "$work/workflow.json" > "$work/unsafe.json"
  if check_contract "$work/unsafe.json" > /dev/null 2>&1; then
    echo "FAIL: unsafe compiler cache mutation accepted: $mutation" >&2
    exit 1
  fi
done
printf 'PASS: test and race coverage retain independent compilation caches and execution\n'
