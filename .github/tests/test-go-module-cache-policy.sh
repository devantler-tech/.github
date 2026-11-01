#!/usr/bin/env bash
# Go module downloads: every job restores, one default-branch job writes, a pull request never writes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
action="${2:-$root/.github/actions/govulncheck/action.yaml}"
yq -o=json . "$workflow" > "$work/workflow.json"
yq -o=json . "$action" > "$work/action.json"
cat > "$work/policy.jq" <<'JQ'
  def default_branch: "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)";
  def pull_request_only($dir):
    "${{ github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && format('go-mod-v1-{0}-{1}-{2}-', runner.os, runner.arch, " + $dir + ") || '' }}";
  # One restore-only module cache directly behind a setup-go that writes nothing itself.
  def restores($steps; $dir):
    ($steps | map(.id // .name)) as $order |
    ($steps | map(select((.uses // "") | startswith("actions/setup-go@")))) as $setup |
    ($steps | map(select(.id == "go-mod-cache-path"))) as $path |
    ($steps | map(select(.id == "go-mod-cache"))) as $restore |
    ($setup|length==1) and ($path|length==1) and ($restore|length==1) and
    ($setup[0].with.cache == false) and ($setup[0].with["cache-dependency-path"] == null) and
    ($path[0].if == null and $restore[0].if == null) and
    ($path[0].shell == "bash") and
    ($path[0].run | contains("cache_path=\"$(go env GOMODCACHE)\"")) and
    ($path[0].run | contains("[[ \"$cache_path\" == /* && \"$cache_path\" != *$'\\n'* ]]")) and
    ($path[0].run | contains("printf 'path=%s\\n' \"$cache_path\" >> \"$GITHUB_OUTPUT\"")) and
    ($restore[0].uses | startswith("actions/cache/restore@")) and
    ($restore[0].with.path == "${{ steps.go-mod-cache-path.outputs.path }}") and
    ($restore[0].with.key ==
      ("go-mod-v1-${{ runner.os }}-${{ runner.arch }}-${{ " + $dir + " }}-${{ hashFiles(format('{0}/go.sum', " + $dir + ")) }}")) and
    ($restore[0].with["restore-keys"] == pull_request_only($dir)) and
    ([$setup[0],$path[0],$restore[0]] | all(."continue-on-error" == null or ."continue-on-error" == false)) and
    (($order|index("go-mod-cache-path")) < ($order|index("go-mod-cache")));
  # MegaLinter runs in a container: the restored modules must reach it through the temp mount.
  def shares_with_megalinter($steps):
    ($steps | map(.id // .name)) as $order |
    ($steps | map(select(.name == "Share Go module cache with MegaLinter"))) as $share |
    ($share | length == 1) and
    ($share[0].if == null) and (($share[0]."continue-on-error" // false) == false) and
    ($share[0].env.GO_MOD_CACHE_PATH == "${{ steps.go-mod-cache-path.outputs.path }}") and
    ($share[0].run | contains("mv \"$GO_MOD_CACHE_PATH\" \"$RUNNER_TEMP/go-mod-cache\"")) and
    ($share[0].run | contains("stat -c %d")) and
    (($steps[] | select(.id == "ml") | .env.GOMODCACHE) == "/github/runner_temp/go-mod-cache") and
    (($order | index("go-mod-cache")) < ($order | index("Share Go module cache with MegaLinter"))) and
    (($order | index("Share Go module cache with MegaLinter")) < ($order | index("ml")));
  # Every Go-cache writer in the workflow, by the path it saves.
  def writers($path):
    [ $workflow[0].jobs | to_entries[] | .key as $job | (.value.steps // [])[]
      | select((.uses // "") | startswith("actions/cache/save@"))
      | select(.with.path == $path) | {job: $job, step: .} ];
  ([ $workflow[0].jobs | to_entries[]
     | select(any((.value.steps // [])[];(.uses // "") | startswith("actions/setup-go@"))) | .key ] | sort) as $go_jobs |
  ($go_jobs == ["build","coverage","deadcode","golangci-lint","lint","test","tidy"]) and
  all($go_jobs[]; . as $id | restores($workflow[0].jobs[$id].steps; "needs.changes.outputs.module-directory")) and
  restores($action[0].runs.steps; "inputs.work-dir") and
  shares_with_megalinter($workflow[0].jobs.lint.steps) and
  # The scanner is the eighth Go setup: it must stay behind the composite action checked above.
  ([ $workflow[0].jobs.govulncheck.steps[] | select((.uses // "") | endswith("/.github/actions/govulncheck")) ] | length >= 1) and
  # No combined cache action anywhere near a Go cache: it would save from every ref.
  ([ ($workflow[0].jobs[].steps // [])[], $action[0].runs.steps[] | select((.uses // "") | test("^actions/cache@")) ] | length == 0) and
  ([ $action[0].runs.steps[] | select((.uses // "") | startswith("actions/cache/save@")) ] | length == 0) and
  (writers("${{ steps.go-mod-cache-path.outputs.path }}") as $mod |
    ($mod | length == 1) and ($mod[0].job == "test") and
    ($mod[0].step.with.key == "${{ steps.go-mod-cache.outputs.cache-primary-key }}") and
    ($mod[0].step.if == ("success() && " + default_branch + " && steps.go-mod-cache.outputs.cache-hit != 'true'")) and
    ($mod[0].step.uses | split("@")[1]) ==
      ($workflow[0].jobs.test.steps[] | select(.id == "go-mod-cache") | .uses | split("@")[1])) and
  (writers("${{ steps.go-build-cache-path.outputs.path }}") as $build |
    ([$build[].job] | sort == ["coverage","test"]) and
    all($build[]; .step.if == ("success() && " + default_branch + " && steps.go-build-cache.outputs.cache-hit != 'true'"))) and
  # The default-branch test run is what populates the archive, so it must keep running there.
  ($workflow[0].jobs.test.if | contains("github.ref == format('refs/heads/{0}', github.event.repository.default_branch)")) and
  ($workflow[0].jobs.test.steps | map(.id // .name) |
    (index("go-mod-cache") < index("🧪 Test")) and (index("🧪 Test") < index("Save Go module cache")))
JQ
check_policy() {
  jq -en --slurpfile workflow "$1" --slurpfile action "$2" -f "$work/policy.jq" > /dev/null
}
if ! check_policy "$work/workflow.json" "$work/action.json"; then
  echo 'FAIL: Go module cache needs restore-only jobs, one default-branch writer and no pull request write' >&2
  exit 1
fi
reject() { # reject <workflow|action> <mutation>
  cp "$work/workflow.json" "$work/unsafe-workflow.json"
  cp "$work/action.json" "$work/unsafe-action.json"
  jq "$2" "$work/$1.json" > "$work/unsafe-$1.json"
  if cmp -s "$work/$1.json" "$work/unsafe-$1.json"; then
    echo "FAIL: mutation changed nothing: $2" >&2
    exit 1
  fi
  if check_policy "$work/unsafe-workflow.json" "$work/unsafe-action.json" > /dev/null 2>&1; then
    echo "FAIL: unsafe module cache mutation accepted ($1): $2" >&2
    exit 1
  fi
}
# A pull request must not write: neither setup-go's own saver nor an ungated or extra save step.
reject workflow '(.jobs.build.steps[] | select((.uses // "") | startswith("actions/setup-go@")) | .with.cache) = true'
reject workflow '(.jobs.tidy.steps[] | select((.uses // "") | startswith("actions/setup-go@")) | .with) |= del(.cache)'
reject workflow '(.jobs.test.steps[] | select(.name == "Save Go module cache") | .if) = "success() && steps.go-mod-cache.outputs.cache-hit != 'true'"'
reject workflow '(.jobs.test.steps[] | select(.name == "Save Go module cache") | .if) = "always()"'
reject workflow '(.jobs.coverage.steps[] | select(.name == "Save Go compilation cache") | .if) = "success() && steps.go-build-cache.outputs.cache-hit != 'true'"'
reject workflow '.jobs.build.steps += [{"name": "Save Go module cache", "uses": "actions/cache/save@x", "with": {"path": "${{ steps.go-mod-cache-path.outputs.path }}", "key": "k"}}]'
reject workflow '(.jobs.lint.steps[] | select(.id == "go-mod-cache") | .uses) |= sub("actions/cache/restore@"; "actions/cache@")'
reject action '(.runs.steps[] | select((.uses // "") | startswith("actions/setup-go@")) | .with.cache) = true'
reject action '(.runs.steps[] | select((.uses // "") | startswith("actions/setup-go@")) | .with["cache-dependency-path"]) = "go.sum"'
reject action '.runs.steps += [{"uses": "actions/cache/save@x", "with": {"path": "p", "key": "k"}}]'
# The restore path must survive: a job that stops restoring, or restores another key, downloads cold.
reject workflow '.jobs.deadcode.steps |= map(select(.id != "go-mod-cache"))'
reject workflow '(.jobs["golangci-lint"].steps[] | select(.id == "go-mod-cache") | .if) = "false"'
reject workflow '(.jobs.coverage.steps[] | select(.id == "go-mod-cache") | .with.key) |= sub("go.sum"; "go.mod")'
reject workflow '(.jobs.build.steps[] | select(.id == "go-mod-cache") | .with["restore-keys"]) = ""'
reject action '.runs.steps |= map(select(.id != "go-mod-cache"))'
reject action '(.runs.steps[] | select(.id == "go-mod-cache") | .with.key) |= sub("go-mod-v1"; "go-mod-v2")'
# The default branch must write a clean archive and keep its one writer.
reject workflow '(.jobs.test.steps[] | select(.id == "go-mod-cache") | .with["restore-keys"]) = "go-mod-v1-"'
reject workflow '.jobs.test.steps |= map(select(.name != "Save Go module cache"))'
reject workflow '(.jobs.test.steps[] | select(.name == "Save Go module cache") | .if) = "false"'
reject workflow '(.jobs.test.steps[] | select(.name == "Save Go module cache") | .with.path) = "~/go"'
reject workflow '.jobs.test.if = "needs.changes.outputs.go == 'true' && github.event_name == 'pull_request'"'
# MegaLinter's own go list must see the restored modules, not download them again.
reject workflow '.jobs.lint.steps |= map(select(.name != "Share Go module cache with MegaLinter"))'
reject workflow '(.jobs.lint.steps[] | select(.name == "Share Go module cache with MegaLinter") | .if) = "false"'
reject workflow '(.jobs.lint.steps[] | select(.name == "Share Go module cache with MegaLinter") | ."continue-on-error") = true'
reject workflow '(.jobs.lint.steps[] | select(.id == "ml") | .env) |= del(.GOMODCACHE)'
reject workflow '(.jobs.lint.steps[] | select(.id == "ml") | .env.GOMODCACHE) = "/root/go/pkg/mod"'
reject workflow '(.jobs.lint.steps[] | select(.name == "Share Go module cache with MegaLinter") | .run) = "true"'
reject workflow '(.jobs.lint.steps[] | select(.name == "Share Go module cache with MegaLinter") | .run) |= gsub("stat -c %d"; "true")'
reject workflow '.jobs.lint.steps |= (map(select(.name == "Share Go module cache with MegaLinter")) + map(select(.name != "Share Go module cache with MegaLinter")))'
printf 'PASS: Go module cache is restored everywhere and written once, on the default branch only\n'
