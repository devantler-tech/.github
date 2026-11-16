#!/usr/bin/env bash
# Exercise the configuration publisher's own-release authority boundary.
# shellcheck disable=SC2016 # Literal GitHub expressions and jq variables.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
guard="$root/.github/scripts/check-manifests-caller.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: own configuration caller: $*" >&2
  exit 1
}
cat >"$work/own.yaml" <<'YAML'
name: Configuration release
on:
  push:
    tags: ["v*"]
permissions: {}
jobs:
  publish-manifests:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    concurrency:
      group: publish-verified-devantler-tech/github-config
      queue: max
      cancel-in-progress: false
    permissions:
      contents: read
      packages: write
      id-token: write
    steps:
      - uses: step-security/harden-runner@1d88384fd173af6ecb012dfd0264a306b711241a
        with:
          egress-policy: audit
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: $/actions/publish-app
        with:
          mode: manifests
          oci-name: devantler-tech/github-config
YAML
yq -o=json '.' "$work/own.yaml" >"$work/baseline.json"
bash "$guard" "$work/own.yaml" >"$work/result" 2>&1 || {
  cat "$work/result" >&2
  fail 'rejected the tag-only own-release publisher'
}
while IFS=$'\t' read -r label mutation; do
  jq "$mutation" "$work/baseline.json" >"$work/caller.json"
  if bash "$guard" "$work/caller.json" >"$work/result" 2>&1; then fail "accepted $label"; fi
  grep -qF 'own-release signing contract' "$work/result" || {
    cat "$work/result" >&2
    fail "$label failed for the wrong reason"
  }
done <<'CASES'
callable mapping	.on.workflow_call={}
callable sequence	.on=["push","workflow_call"]
callable scalar	.on="workflow_call"
manual trigger	.on.workflow_dispatch={}
branch trigger	.on.push.branches=["main"]
all tags	.on.push.tags=["*"]
workflow permission	.permissions.contents="write"
job permission	.jobs["publish-manifests"].permissions.contents="write"
extra job	.jobs.other={"runs-on":"ubuntu-latest","steps":[{"run":"true"}]}
extra step	.jobs["publish-manifests"].steps += [{"run":"true"}]
caller action replacement	.jobs["publish-manifests"].steps[2].uses="outside/publish@main"
caller checkout replacement	.jobs["publish-manifests"].steps[1].with.repository="outside/source"
mutable checkout	.jobs["publish-manifests"].steps[1].with.ref="main"
persisted credential	.jobs["publish-manifests"].steps[1].with["persist-credentials"]=true
wrong publication mode	.jobs["publish-manifests"].steps[2].with.mode="deployment"
wrong artifact	.jobs["publish-manifests"].steps[2].with["oci-name"]="devantler-tech/other"
different lock	.jobs["publish-manifests"].concurrency.group="publish-devantler-tech/github-config"
replacing queue	.jobs["publish-manifests"].concurrency.queue="single"
cancelling release	.jobs["publish-manifests"].concurrency["cancel-in-progress"]=true
ambient environment	.env.GITHUB_TOKEN="unexpected"
conditional publication	.jobs["publish-manifests"].steps[2].if="false"
CASES
{
  cat "$work/own.yaml"
  printf '\n---\n'
  cat "$work/own.yaml"
} >"$work/multiple.yaml"
if bash "$guard" "$work/multiple.yaml" >"$work/result" 2>&1; then fail 'accepted multiple documents'; fi
echo 'ok own configuration publisher is tag-only, non-callable and bound to its own source and shared publication lock'
