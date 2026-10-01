#!/usr/bin/env bash
# Behavioral controls: breaking a decision or head pin must fail the executed
# fixture, independently of the workflow boundary's structural checks.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
yq -o=json '.' "$root/.github/workflows/enable-auto-merge.yaml" >"$work/workflow.json"
count=0
while IFS=$'\t' read -r label mutation diagnostic; do
  jq "$mutation" "$work/workflow.json" >"$work/mutated.json"
  if bash "$root/.github/tests/test-auto-merge-fixture.sh" "$work/mutated.json" >"$work/result" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/result" || {
    cat "$work/result" >&2
    exit 1
  }
  count=$((count + 1))
done <<'CASES'
no approval	.jobs["auto-merge"].steps |= map(if .id == "approve" then .run="true" else . end)	approve and arm exactly once
no arming	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .run="true" else . end)	approve and arm exactly once
wrong approved head	.jobs["auto-merge"].steps |= map(if .id == "approve" then .run |= sub("commit_id=\\\"\\$HEAD_SHA\\\"";"commit_id=wrong-head") else . end)	unexpected offline GitHub command
wrong armed head	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .run |= sub("--match-head-commit \\\"\\$HEAD_SHA\\\"";"--match-head-commit wrong-head") else . end)	unexpected offline GitHub command
default gate rejected	.jobs["auto-merge"].steps |= map(if .id == "gates" then .run |= gsub("armable=true";"armable=false") else . end)	lifecycle was not armable
reviewer gate accepted	.jobs["auto-merge"].steps |= map(if .id == "gates" then .run |= gsub("armable=false";"armable=true") else . end)	reviewer event became armable
approval error swallowed	.jobs["auto-merge"].steps |= map(if .id == "approve" then .run |= gsub("exit 1";"exit 0") else . end)	approval API error accepted
failed approval armed	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .run |= (split("if [[ \"$APPROVE_OUTCOME\" != \"success\" ]]; then") | join("if false; then")) else . end)	failed approval armed
enforced handoff removed	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .run |= (split("if [[ \"$ENFORCED\" == \"true\" ]]; then") | join("if false; then")) else . end)	enforced cleanup or approval was bypassed
duplicate approval	.jobs["auto-merge"].steps += [.jobs["auto-merge"].steps[] | select(.id == "approve")]	expected exactly one approve
wrong approval forwarding	.jobs["auto-merge"].steps |= map(if .id == "approve" then .env.HEAD_SHA="wrong-head" else . end)	workflow output bindings
enforcement forwarding lost	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .env.ENFORCED="false" else . end)	workflow output bindings
gate head forwarding lost	.jobs["auto-merge"].steps |= map(if .id == "gates" then .env.HEAD_SHA="wrong-head" else . end)	workflow output bindings
approval outcome forwarding lost	.jobs["auto-merge"].steps |= map(if .name == "🔀 Enable Auto-Merge" then .env.APPROVE_OUTCOME="success" else . end)	workflow output bindings
wrong cleanup target	.jobs["auto-merge"].steps |= map(if .id == "approve" then .run |= (split("\"$REPOSITORY\" \"$PR_NUMBER\"") | join("\"fixture/wrong\" \"$PR_NUMBER\"")) else . end)	unexpected offline GitHub command
CASES
echo "PASS: executed auto-merge fixture rejects $count independent decision regressions"
