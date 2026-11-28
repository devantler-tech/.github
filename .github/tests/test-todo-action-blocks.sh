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
unconditional project token	.runs.steps |= map(if .id == "app-token" then .if=null else . end)	the project token must come from the broker step alone
default-on project authentication	.inputs["optional-project-auth"].default="true"	the project token must come from the broker step alone
another broker identity	.runs.steps |= map(if .id == "app-token" then .with.identity="template-sync" else . end)	the project token must come from the broker step alone
restored App key	.runs.steps |= map(if .id == "app-token" then .with["private-key"]="${{ secrets.APP_PRIVATE_KEY }}" else . end)	the project token must come from the broker step alone
App-key token action restored	.runs.steps |= map(if .id == "app-token" then .uses="actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510" else . end)	the project token must come from the broker step alone
mutable broker action	.runs.steps |= map(if .id == "app-token" then .uses="octo-sts/action@v1" else . end)	the project token must come from the broker step alone
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
mutable image tag	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .env.TODO_TO_ISSUE_IMAGE |= split("@")[0] else . end)	the project token must come from the broker step alone
lower image floor	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .env.TODO_TO_ISSUE_IMAGE |= sub("v5.1.15"; "v5.0.0") else . end)	the project token must come from the broker step alone
retired vendor input restored	.inputs["exclude-vendored"]={default:"true",required:false}	vendor filtering must be permanent and guarded by an empty ignore
unguarded vendor filtering	.runs.steps |= map(if .id == "vendored-ignore" then .if=null else . end)	vendor filtering must be permanent and guarded by an empty ignore
vendor filter omits sources	.runs.steps |= map(if .id == "vendored-ignore" then .run="printf \u0027ignore=\\n\u0027 >>\"$GITHUB_OUTPUT\"\n" else . end)	Vendor output must remain a fixed literal
vendor filter skips all sources	.runs.steps |= map(if .id == "vendored-ignore" then .run="printf \u0027ignore=.*\\n\u0027 >>\"$GITHUB_OUTPUT\"\n" else . end)	Vendor output must remain a fixed literal
scanner replay	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("docker run --rm"; "retry docker run --rm") else . end)	scanner-fails-once: exact Docker projection or retry count changed
missing supervisor entrypoint	.runs.steps |= map(if .name == "📝 Create issues from TODOs" then .run |= sub("/opt/todo-guard"; "/unexpected") else . end)	exact Docker projection or retry count changed
CASES
echo 'PASS: 24 independent to-do action mutations are rejected'
