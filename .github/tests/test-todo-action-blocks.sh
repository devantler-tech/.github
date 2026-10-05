#!/usr/bin/env bash
# Independent regressions must fail the actual wrapper tests for the intended reason.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash "$root/.github/tests/test-todo-action.sh" >"$work/baseline" 2>&1 || {
  cat "$work/baseline" >&2
  exit 1
}
yq -o=json '.' "$root/actions/create-issues-from-todos/action.yaml" >"$work/action.json"
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/action.json" >"$work/mutated.json"
  if bash "$root/.github/tests/test-todo-action.sh" "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    echo "FAIL: $label failed for the wrong reason" >&2
    cat "$work/result" >&2
    exit 1
  }
  echo "PASS: rejects $label"
done <<'CASES'
unconditional project token	.runs.steps |= map(if .id == "app-token" then .if=null else . end)	project authentication must be optional
default-on project authentication	.inputs["optional-project-auth"].default="true"	project authentication must be optional
unconditional new validation	.runs.steps[0].if=null	project authentication must be optional
lost legacy App inputs	.runs.steps |= map(if .id == "app-token" then del(.with["private-key"]) else . end)	project authentication must be optional
missing credential validation	.runs.steps[0].run=":"	invalid project credentials were accepted
missing ignore forwarding	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("--env INPUT_IGNORE"; "--env INPUT_OMITTED") else . end)	exact Docker projection or retry count changed
missing commit forwarding	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("--env INPUT_COMMITS"; "--env INPUT_OMITTED") else . end)	exact Docker projection or retry count changed
missing repository ID forwarding	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("--env INPUT_REPOSITORY_ID"; "--env INPUT_OMITTED") else . end)	exact Docker projection or retry count changed
wrong repository ID binding	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .env.INPUT_REPOSITORY_ID="4243" else . end)	exact Docker projection or retry count changed
wrong issue token	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run = "INPUT_TOKEN=unexpected\n"+.run else . end)	no-project: expected exit 0, got 74
wrong project token	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run = "INPUT_PROJECTS_SECRET=unexpected\n"+.run else . end)	no-project: expected exit 0, got 74
wrong workdir	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("/github/workspace"; "/unexpected") else . end)	exact Docker projection or retry count changed
missing retry	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("retry docker pull"; "docker pull") else . end)	transient-recovery: expected exit 0, got 73
swallowed terminal error	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run = (.run | sub("set -euo pipefail"; "set -uo pipefail")) + "\ntrue\n" else . end)	terminal-failure: expected exit 73, got 0
missing preserved helper	.runs.steps |= map(if .name == "🧰 Preserve retry helper" then .run=":" else . end)	supervisor was not preserved
mutable image tag	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .env.TODO_TO_ISSUE_IMAGE |= split("@")[0] else . end)	project authentication must be optional
lower image floor	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .env.TODO_TO_ISSUE_IMAGE |= sub("v5.1.15"; "v5.0.0") else . end)	project authentication must be optional
default-on vendor filtering	.inputs["exclude-vendored"].default="true"	vendor filtering must be guarded and default off
unguarded vendor filtering	.runs.steps |= map(if .id == "vendored-ignore" then .if=null else . end)	vendor filtering must be guarded and default off
vendor filter omits sources	.runs.steps |= map(if .id == "vendored-ignore" then .run="printf \u0027ignore=\\n\u0027 >>\"$GITHUB_OUTPUT\"\n" else . end)	Vendor output must remain a fixed literal
vendor filter skips all sources	.runs.steps |= map(if .id == "vendored-ignore" then .run="printf \u0027ignore=.*\\n\u0027 >>\"$GITHUB_OUTPUT\"\n" else . end)	Vendor output must remain a fixed literal
scanner replay	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("docker run --rm"; "retry docker run --rm") else . end)	scanner-fails-once: exact Docker projection or retry count changed
missing supervisor entrypoint	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("/opt/todo-guard"; "/unexpected") else . end)	exact Docker projection or retry count changed
CASES
echo 'PASS: 23 independent to-do action mutations are rejected'
