#!/usr/bin/env bash
# Pin the credentials held by executed catalogue Go-validation jobs.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/validate-go-project-readonly.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
production="${3:-$root/.github/workflows/validate-go-project.yaml}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$workflow" >"$work/workflow.json"
yq -o=json '.' "$ci" >"$work/ci.json"
yq -o=json '.' "$production" >"$work/production.json"
node --input-type=module - "$work" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const dir = process.argv[2];
const w = JSON.parse(fs.readFileSync(`${dir}/workflow.json`));
const ci = JSON.parse(fs.readFileSync(`${dir}/ci.json`));
const production = JSON.parse(fs.readFileSync(`${dir}/production.json`));
const interfaces = Object.values(ci.jobs).filter(j => j.uses === './.github/workflows/validate-go-project.yaml');
assert.equal(interfaces.length, 1, 'production workflow must have only its non-executing interface call');
assert.deepEqual(interfaces[0].with, {'working-directory': '', 'apply-signed-fixes': false}, 'production interface selected executable validation');
assert.equal(interfaces[0].secrets, undefined, 'production interface forwarded credentials');
assert.deepEqual(production.jobs.lint.needs, ['changes'], 'production reporter lost its skipped prerequisite');
assert.doesNotMatch(production.jobs.lint.if, /\b(always|success|failure|cancelled)\s*\(/i, 'production reporter overrides skipped prerequisite');
const callers = Object.values(ci.jobs).filter(j => j.uses === './.github/workflows/validate-go-project-readonly.yaml');
assert.equal(callers.length, 5, 'all five Go fixture callers must remain');
for (const j of callers) {
  assert.deepEqual(j.permissions, {contents: 'read', 'pull-requests': 'read', 'code-quality': 'write'}, 'fixture grants mutation permissions');
  assert.equal(j.secrets, undefined, 'fixture forwards a secret');
}
assert.equal(w.on.workflow_call.secrets, undefined, 'read-only entrypoint accepts a secret');
assert.equal(w.on.pull_request, undefined, 'read-only entrypoint must not become an org-required direct run');
assert.equal(w.on.workflow_call.inputs['apply-signed-fixes'].default, false);
assert.notEqual(w.concurrency.group, production.concurrency.group, 'entrypoints must not cancel one another');
assert.deepEqual(w.permissions, {});
const safe = w.jobs.lint;
assert.ok(safe, 'missing actual read-only lint job');
assert.deepEqual(safe.permissions, {contents: 'read'});
assert.equal(safe.env.GITHUB_TOKEN, '');
assert.equal(safe.env.GITHUB_COMMENT_REPORTER, false);
assert.equal(safe.env.GITHUB_STATUS_REPORTER, false);
const expectedSteps = structuredClone(production.jobs.lint.steps);
delete expectedSteps.find(s => s.id === 'ml').env.GITHUB_TOKEN;
assert.deepEqual(safe.steps, expectedSteps, 'both entrypoints must execute the same lint and fixer steps');
assert.deepEqual(safe.outputs, production.jobs.lint.outputs);
assert.equal(safe['continue-on-error'] ?? false, false);
assert.equal(production.jobs.lint.steps.find(s => s.id === 'ml').env.GITHUB_TOKEN, '${{ secrets.GITHUB_TOKEN }}', 'normal reporting token lost');
assert.deepEqual(production.jobs.lint.permissions, {contents: 'read', issues: 'write', 'pull-requests': 'write'});
const retained = Object.keys(production.jobs).filter(id => !id.startsWith('apply-')).sort();
assert.deepEqual(Object.keys(w.jobs).sort(), retained, 'validation removed or signer remains reachable');
const scalars = value => typeof value === 'string' ? [value] :
  value && typeof value === 'object' ? Object.values(value).flatMap(scalars) : [];
for (const [id, job] of Object.entries(w.jobs)) {
  assert.equal(job.permissions?.contents, 'read', `${id}: contents is not read-only`);
  for (const [scope, grant] of Object.entries(job.permissions)) {
    assert.ok(grant !== 'write' || (id === 'coverage' && scope === 'code-quality'), `${id}: unsafe write ${scope}`);
  }
  for (const scalar of scalars([w.env, job])) {
    assert.doesNotMatch(scalar, /secrets\s*[.\[]|github\s*(?:\.token|\[\s*["']token)|toJSON\s*\(\s*(?:secrets|github)/i, `${id}: forwarded secret or reporter token`);
  }
  if (id !== 'lint') assert.deepEqual(job.steps, production.jobs[id].steps, `${id}: production validation steps changed`);
}
assert.deepEqual(safe.env, {...production.jobs.lint.env, GITHUB_TOKEN: '', GITHUB_COMMENT_REPORTER: false, GITHUB_STATUS_REPORTER: false}, 'read-only lint environment differs from production');
// Evaluate the shipped admission expressions for both modes and all diff states.
const evaluate = (expr, values) => {
  let code = expr.replace(/^\s*\$\{\{\s*|\s*\}\}\s*$/g, '');
  for (const key of Object.keys(values).sort((a,b) => b.length-a.length)) code = code.split(key).join(JSON.stringify(values[key]));
  return Function(`"use strict"; return (${code});`)();
};
// A selected self-test must reach its real commands on workflow-only diffs.
// Production and all other callers retain the original path-filter result.
for (const go of ['true', 'false']) {
  assert.equal(evaluate(production.jobs.changes.outputs.go, {'steps.filter.outputs.go': go}), go, 'production Go filter changed');
  for (const repository of ['devantler-tech/.github', 'devantler-tech/ksail']) {
    for (const directory of ['.github/tests/go-valid-fixture', '', 'another-module']) {
      const fixture = repository === 'devantler-tech/.github' && directory === '.github/tests/go-valid-fixture';
      assert.equal(evaluate(w.jobs.changes.outputs.go, {
        'steps.filter.outputs.go': go, 'github.repository': repository, 'inputs.working-directory': directory
      }), fixture ? 'true' : go, 'fixture validation admission');
    }
  }
}
for (const event of ['pull_request', 'push', 'merge_group']) {
  assert.equal(evaluate(production.jobs.changes.if, {'inputs.working-directory': '', 'github.repository': 'devantler-tech/.github', 'github.event_name': event}), false, 'production interface became executable');
}
for (const go of ['true', 'false']) for (const lintable of ['true', 'false']) {
  const values = {'needs.changes.outputs.go': go, 'needs.changes.outputs.lintable': lintable};
  const changed = go === 'true' || lintable === 'true';
  assert.equal(evaluate(safe.if, values), changed, 'read-only lint admission');
}
const signed = w.jobs.changes.outputs['signed-fixes'];
for (const enabled of [false, true]) for (const direct of [false, true]) {
  const values = {'inputs.apply-signed-fixes': enabled, 'toJSON(inputs)': direct ? '{}' : '{"apply-signed-fixes":false}', "contains(github.workflow_ref, '/.github/workflows/validate-go-project.yaml@')": direct};
  assert.equal(evaluate(signed, values), false, 'signed-fix admission');
}
assert.ok(safe.steps.some(s => s.uses?.startsWith('oxsecurity/megalinter/')), 'real lint removed');
assert.ok(safe.steps.some(s => s.id === 'fixes'), 'fix exporter removed');
assert.ok(safe.steps.some(s => s.run?.includes('exit 1')), 'read-only dirty-tree rejection removed');
assert.ok(w.jobs.build.steps.some(s => s.run?.includes('go build')), 'real build removed');
assert.ok(w.jobs.test.steps.some(s => s.run?.includes('go test')), 'real tests removed');
assert.ok(w.jobs.coverage.steps.some(s => s.run?.includes('go test -race -coverprofile')), 'real coverage removed');
assert.ok(w.jobs.coverage.steps.some(s => s.uses?.endsWith('/actions/upload-coverage')), 'coverage upload removed');
assert.equal(w.jobs.coverage.permissions['code-quality'], 'write', 'coverage upload permission missing');
console.log('PASS: five credential-safe callers; four lint admissions; four signed-fix denials; normal reporting and real validation retained');
JS
# Execute the actual dirty-tree gate from the read-only job.
yq -r '.jobs.lint.steps[] | select(.name == "❌ Fail if uncommitted changes remain (read-only mode)") | .run' "$workflow" >"$work/dirty-gate.sh"
mkdir "$work/fixture"
git -C "$work/fixture" init -q
printf 'original\n' >"$work/fixture/file"
git -C "$work/fixture" add file
git -C "$work/fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture
(cd "$work/fixture" && bash -euo pipefail "$work/dirty-gate.sh")
printf 'changed\n' >"$work/fixture/file"
if (cd "$work/fixture" && bash -euo pipefail "$work/dirty-gate.sh") >"$work/result" 2>&1; then
  echo 'FAIL: non-mutating lint accepted a dirty tree' >&2
  exit 1
fi
grep -qF 'Auto-fix produced changes while signed fix commits are disabled' "$work/result"
[[ "$(cat "$work/fixture/file")" == changed ]]
echo 'PASS: shipped read-only lint gate accepts clean state and rejects changes without discarding them'
bash "$root/.github/scripts/generate-go-readonly.sh" "$production" "$work/generated.yaml"
yq -o=json '.' "$work/generated.yaml" | jq -S '.' >"$work/generated.json"
jq -S '.' "$work/workflow.json" >"$work/checked.json"
cmp "$work/generated.json" "$work/checked.json" || {
  echo 'FAIL: read-only workflow differs from its production projection; regenerate it' >&2
  exit 1
}
echo 'PASS: complete generated workflow matches current production source'
