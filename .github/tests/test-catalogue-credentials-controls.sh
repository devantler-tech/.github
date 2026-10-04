#!/usr/bin/env bash
# Mutate real CI and callee sources, then require the full graph guard to reject each defect.
set -euo pipefail
root="$(pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$root/.github/tests/catalogue-credentials" && go test ./... && go build -o "$tmp/guard" .)
mkdir -p "$tmp/catalogue/.github"
cp -R "$root/.github/workflows" "$tmp/catalogue/.github/workflows"
cp -R "$root/.github/actions" "$tmp/catalogue/.github/actions"
cp -R "$root/.github/fixtures" "$tmp/catalogue/.github/fixtures"
mkdir -p "$tmp/catalogue/.github/tests"
# Some hosted controls are local composite actions, not scripts to execute.
cp -R "$root/.github/tests" "$tmp/catalogue/.github/tests"
cp -R "$root/actions" "$tmp/catalogue/actions"
# Avoid network fallbacks: control fixtures must classify the exact copied sources.
export CATALOGUE_CREDENTIALS_OFFLINE=1
"$tmp/guard" "$tmp/catalogue"
controls=0
# Each expected diagnostic is an authority class; no credential value is printed.
while IFS=$'\t' read -r label path mutation expected_status diagnostic; do
  [[ -n "$label" ]] || continue
  yq -o=json '.' "$root/$path" > "$tmp/source.json"
  jq "$mutation" "$tmp/source.json" > "$tmp/catalogue/$path"
  status=0
  "$tmp/guard" "$tmp/catalogue" > "$tmp/result" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]]; then
    cat "$tmp/result" >&2
    echo "FAIL: $label returned $status, expected $expected_status" >&2
    exit 1
  fi
  if ! grep -Fq "$diagnostic" "$tmp/result"; then
    cat "$tmp/result" >&2
    echo "FAIL: $label rejected for the wrong reason" >&2
    exit 1
  fi
  cp "$root/$path" "$tmp/catalogue/$path"
  controls=$((controls + 1))
done <<'CASES'
new root writer	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"write"},steps:[{run:"echo fixture"}]}	1	write authority
new root secret	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"read"},env:{EXTRA:"${{ secrets.TOKEN }}"},steps:[{run:"echo fixture"}]}	1	external secret
bracket secret	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"read"},env:{EXTRA:"${{ SeCrEtS['TOKEN'] }}"},steps:[{run:"echo fixture"}]}	1	external secret
container secret	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"read"},container:{image:"fixture",credentials:{password:"${{ secrets.TOKEN }}"}},steps:[{run:"echo fixture"}]}	1	external secret
unclassified permission	.github/workflows/ci.yaml	.jobs.new={permissions:{"future-scope":"write"},steps:[{run:"echo fixture"}]}	2	UNKNOWN
missing authority	.github/workflows/ci.yaml	del(.permissions)|.jobs.new={steps:[{run:"echo fixture"}]}	2	UNKNOWN
bulk secret forwarding	.github/workflows/ci.yaml	.jobs["test-template-sync"].secrets="inherit"	1	external secret
mutable callee	.github/workflows/ci.yaml	.jobs["test-template-sync"].uses="devantler-tech/.github/.github/workflows/template-sync.yaml@main"	2	UNKNOWN
missing callee	.github/workflows/ci.yaml	.jobs["test-template-sync"].uses="./.github/workflows/missing.yaml"	2	UNKNOWN
removed template dry run	.github/workflows/ci.yaml	del(.jobs["test-template-sync"].with["dry-run"])	1	write authority
restored template writer	.github/workflows/template-sync.yaml	del(.jobs["template-sync"].if)	1	write authority
restored skills writer	.github/workflows/update-agent-skills.yaml	del(.jobs["update-agent-skills"].if)	1	write authority
removed skipped dependency	.github/workflows/update-agent-skills.yaml	del(.jobs["open-skill-pull-requests"].needs)	1	write authority
always restores skipped writer	.github/workflows/update-agent-skills.yaml	.jobs["open-skill-pull-requests"].if="${{ always() }}"	1	write authority
restored auto merge	.github/workflows/enable-auto-merge.yaml	.jobs["disarm-untrusted-update"].if="true"	1	write authority
restored pages writer	.github/workflows/deploy-github-pages.yaml	del(.jobs.build.if)	1	write authority
restored package writer	.github/workflows/publish-dotnet-library.yaml	del(.jobs.publish.if)	1	write authority
restored application writer	.github/workflows/publish-app.yaml	del(.jobs.publish.if)	1	write authority
restored manifest writer	.github/workflows/publish-manifests.yaml	del(.jobs["publish-manifests"].if)	1	write authority
unknown condition on new writer	.github/workflows/ci.yaml	.jobs.new={"if":"${{ vars.MAYBE }}",permissions:{issues:"write"},steps:[{run:"echo fixture"}]}	1	write authority
nested composite secret	.github/actions/prepare-fixes/action.yaml	.runs.steps += [{run:"echo fixture",shell:"bash",env:{EXTRA:"${{ secrets.TOKEN }}"}}]	1	external secret
mixed bulk secret	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"read"},env:{EXTRA:"${{ secrets.GITHUB_TOKEN && toJSON(secrets) }}"},steps:[{run:"echo fixture"}]}	1	external secret
new CI trigger	.github/workflows/ci.yaml	.on.pull_request_target={}|.jobs.new={"if":"${{ github.event_name == 'pull_request_target' }}",permissions:{contents:"write"},steps:[{run:"echo fixture"}]}	1	write authority
environment secret override	.github/workflows/ci.yaml	.jobs.new={permissions:{contents:"read"},environment:"fixture",steps:[{run:"echo fixture"}]}	2	UNKNOWN environment-secret
opaque token comparison	.github/workflows/ci.yaml	.jobs.new={"if":"${{ github.token != 'github-token' }}",permissions:{contents:"write"},steps:[{run:"echo fixture"}]}	1	write authority
unmeasured checkout destination	.github/workflows/ci.yaml	(.jobs["test-validate-retired-repo-links"].steps[]|select((.uses // "")|startswith("actions/checkout@"))).with.path="${{ vars.DESTINATION }}"	2	UNKNOWN local action checkout
missing guard entrypoint	.github/workflows/ci.yaml	.jobs["lint-ci-coverage-parity"].steps |= map(select(.run != "bash .github/tests/test-catalogue-credentials.sh"))	1	required guard wiring
conditional guard entrypoint	.github/workflows/ci.yaml	(.jobs["lint-ci-coverage-parity"].steps[]|select(.run == "bash .github/tests/test-catalogue-credentials.sh")).if="false"	1	required guard wiring
ignored guard failure	.github/workflows/ci.yaml	(.jobs["lint-ci-coverage-parity"].steps[]|select(.run == "bash .github/tests/test-catalogue-credentials-controls.sh"))["continue-on-error"]=true	1	required guard wiring
guard job dependency	.github/workflows/ci.yaml	.jobs["lint-ci-coverage-parity"].needs="test-template-sync"	1	required guard wiring
ignored guard job failure	.github/workflows/ci.yaml	.jobs["lint-ci-coverage-parity"]["continue-on-error"]=true	1	required guard wiring
missing required guard result	.github/workflows/ci.yaml	.jobs["ci-required-checks"].needs |= map(select(. != "lint-ci-coverage-parity"))	1	required guard wiring
unconsumed required guard result	.github/workflows/ci.yaml	(.jobs["ci-required-checks"].steps[]|select(.env.JOB_RESULTS != null)).run="echo fixture"	1	required guard wiring
CASES
[[ "$controls" == 33 ]] || { echo 'FAIL: incomplete control set' >&2; exit 1; }
echo "PASS: complete source graph rejects $controls real-source credential regressions"
