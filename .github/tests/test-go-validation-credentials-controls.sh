#!/usr/bin/env bash
# Restoring mutation credentials or admitting a privileged job must fail.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/validate-go-project-readonly.yaml" >"$work/workflow.json"
yq -o=json '.' "$root/.github/workflows/ci.yaml" >"$work/ci.json"
yq -o=json '.' "$root/.github/workflows/validate-go-project.yaml" >"$work/production.json"
count=0
while IFS=$'\t' read -r source mutation diagnostic; do
  input="$source"
  [[ "$source" != projection ]] || input=production
  jq "$mutation" "$work/$input.json" >"$work/mutated.json"
  workflow="$work/workflow.json"
  ci="$work/ci.json"
  production="$work/production.json"
  if [[ "$source" == workflow ]]; then
    workflow="$work/mutated.json"
  elif [[ "$source" == ci ]]; then
    ci="$work/mutated.json"
  else
    production="$work/mutated.json"
    workflow="$work/projected.yaml"
    bash "$root/.github/scripts/generate-go-readonly.sh" "$production" "$workflow"
  fi
  if bash "$root/.github/tests/test-go-validation-credentials.sh" "$workflow" "$ci" "$production" >"$work/result" 2>&1; then
    echo "FAIL: credential regression accepted: $mutation" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
ci	.jobs["test-validate-go-project"].permissions.issues="write"	fixture grants mutation permissions
ci	.jobs["test-validate-go-project"].secrets.APP_PRIVATE_KEY="${{ secrets.APP_PRIVATE_KEY }}"	fixture forwards a secret
ci	.jobs["test-validate-go-project"].uses="./.github/workflows/validate-go-project.yaml"	production workflow must have only its non-executing interface call
ci	.jobs["test-validate-go-project-interface"].with["working-directory"]=".github/tests/go-valid-fixture"	production interface selected executable validation
workflow	.jobs.lint.permissions["pull-requests"]="write"	Expected values to be strictly deep-equal
workflow	.jobs.lint.env.TOKEN="${{ github.token }}"	lint: forwarded secret or reporter token
workflow	.jobs.lint.env.TOKEN="${{\n GITHUB [ \"TOKEN\" ]\n}}"	lint: forwarded secret or reporter token
workflow	.jobs.lint.env.TOKEN="${{\n toJson(\n Secrets\n )\n}}"	lint: forwarded secret or reporter token
workflow	.jobs.lint.env.TOKEN="${{ SECRETS [ \"GITHUB_TOKEN\" ] }}"	lint: forwarded secret or reporter token
projection	.jobs.build.steps[0].env.TOKEN="${{\n GITHUB [ \"TOKEN\" ]\n}}"	build: forwarded secret or reporter token
projection	.jobs.build.steps[0].env.TOKEN="${{\n toJson(\n Secrets\n )\n}}"	build: forwarded secret or reporter token
projection	.jobs.lint.if="always()"	production reporter overrides skipped prerequisite
workflow	.jobs.build.permissions.contents="write"	build: contents is not read-only
workflow	.jobs.coverage.permissions.issues="write"	coverage: unsafe write issues
workflow	.jobs.extra={"permissions":{"contents":"read","issues":"write"},"steps":[]}	validation removed or signer remains reachable
workflow	.jobs.lint.if="true"	read-only lint admission
workflow	.jobs.changes.outputs["signed-fixes"]="${{ inputs.apply-signed-fixes == true }}"	signed-fix admission
workflow	.jobs.lint.steps |= map(if .id=="fixes" then .with["upload-enabled"]="true" else . end)	both entrypoints must execute the same lint and fixer steps
workflow	.jobs.coverage.permissions["code-quality"]="read"	coverage upload permission missing
workflow	.jobs.changes.outputs.go="${{ steps.filter.outputs.go }}"	fixture validation admission
workflow	.jobs.changes.outputs.go="true"	fixture validation admission
workflow	.jobs.changes.outputs.go="${{ inputs.working-directory == '.github/tests/go-valid-fixture' && 'true' || steps.filter.outputs.go }}"	fixture validation admission
CASES
jq '.jobs.lint.env.SAMPLE_VALIDATION_SETTING="retained"' "$work/production.json" >"$work/with-env.json"
bash "$root/.github/scripts/generate-go-readonly.sh" "$work/with-env.json" "$work/with-env.yaml"
bash "$root/.github/tests/test-go-validation-credentials.sh" "$work/with-env.yaml" "$work/ci.json" "$work/with-env.json" >"$work/result" 2>&1
yq -o=json 'del(.jobs.lint.env.SAMPLE_VALIDATION_SETTING)' "$work/with-env.yaml" >"$work/dropped-env.json"
if bash "$root/.github/tests/test-go-validation-credentials.sh" "$work/dropped-env.json" "$work/ci.json" "$work/with-env.json" >"$work/result" 2>&1; then
  echo 'FAIL: projection discarded a production validation setting' >&2
  exit 1
fi
grep -qF 'read-only lint environment differs from production' "$work/result"
count=$((count + 1))
echo "PASS: $count independent credential, reachability and coverage regressions rejected"
