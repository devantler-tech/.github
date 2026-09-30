#!/usr/bin/env bash
# Behaviour test for sync-cluster-policies.yaml's "Verify allowlisted policies still
# exist upstream" step (#320). It runs the step's own `run` block, extracted from the
# workflow, against a fake upstream clone and a fake caller .policyignore, so the test
# exercises the shipped script rather than a copy of it. The ablation arm removes the
# guard's `exit 1` and requires the missing-path case to pass, proving the guard (and
# not some other failure) is what refuses it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/sync-cluster-policies.yaml"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script="$work/verify.sh"
yq '.jobs["sync-policies"].steps[] | select(.id == "verify-allowlist") | .run' "$workflow" >"$script"
if [ ! -s "$script" ] || [ "$(cat "$script")" = "null" ]; then
  fail "no verify-allowlist step found in $workflow"
fi

upstream="$work/upstream"
mkdir -p "$upstream/best-practices/add-ns-quota" "$upstream/other/create-pod-antiaffinity"
touch "$upstream/best-practices/add-ns-quota/add-ns-quota.yaml" \
  "$upstream/other/create-pod-antiaffinity/create-pod-antiaffinity.yaml"
mkdir -p "$upstream/.git" && touch "$upstream/.git/config"
ln -s .git "$upstream/alias"
ln -s create-pod-antiaffinity/create-pod-antiaffinity.yaml "$upstream/other/linked.yaml"

# run <label> <policyignore content | "-" for no file> [script]
run() {
  local label="$1" content="$2" body="${3:-$script}" caller
  caller="$work/caller-$(tr -c '[:alnum:]' '-' <<<"$label")"
  mkdir -p "$caller"
  [ "$content" = "-" ] || printf '%b' "$content" >"$caller/.policyignore"
  (cd "$caller" && KYVERNO_POLICIES_TEMP_DIR="$upstream" bash -e "$body" 2>&1)
}

passes() {
  local out
  out="$(run "$@")" || fail "$1 — expected success, got: $out"
  echo "ok: $1"
}

refuses() {
  local label="$1" content="$2" message="$3" out
  if out="$(run "$label" "$content")"; then
    fail "$label — expected failure, got success: $out"
  fi
  grep -qF "$message" <<<"$out" || fail "$label — refused for the wrong reason: $out"
  echo "ok: $label"
}

passes "every literal re-include exists upstream" \
  '*\n!best-practices/add-ns-quota/add-ns-quota.yaml\n!other/create-pod-antiaffinity/create-pod-antiaffinity.yaml\n'
passes "a directory re-include with a trailing slash exists upstream" \
  '*\n!other/create-pod-antiaffinity/\n'
passes "a CRLF .policyignore still resolves its paths" \
  '*\r\n!best-practices/add-ns-quota/add-ns-quota.yaml\r\n'
passes "a glob re-include that matches nothing is left to the filter" \
  '*\n!pod-security/*\n'
passes "comments and plain ignore patterns are not treated as re-includes" \
  '# !gone/policy.yaml\nother/*\n'
passes "no .policyignore at all is not this step's concern (#262)" "-"

refuses "a literal re-include that upstream dropped" \
  '*\n!best-practices/add-ns-quota/add-ns-quota.yaml\n!other/spread-pods-across-topology/spread-pods-across-topology.yaml\n' \
  "re-includes 'other/spread-pods-across-topology/spread-pods-across-topology.yaml'"

refuses "a final re-include without a trailing newline is still checked" \
  '*\n!gone/policy.yaml' \
  "re-includes 'gone/policy.yaml'"

refuses "a re-include into .git is never kept, even though it exists" \
  '*\n!.git/config\n' "re-includes '.git/config'"
refuses "a re-include that escapes the clone is never kept" \
  '*\n!../upstream/best-practices/add-ns-quota/add-ns-quota.yaml\n' "re-includes '../upstream/"
refuses "an absolute re-include is never kept, even when the file exists" \
  '*\n!/etc/hosts\n' "re-includes '/etc/hosts'"
refuses "a re-include through a symlinked directory is never kept, even into .git" \
  '*\n!alias/config\n' "re-includes 'alias/config'"
refuses "a re-include of a symlinked file is never kept" \
  '*\n!other/linked.yaml\n' "re-includes 'other/linked.yaml'"

out="$(run "two missing paths" '*\n!gone/a.yaml\n!gone/b.yaml\n')" && fail "two missing paths — expected failure"
for p in gone/a.yaml gone/b.yaml; do
  grep -qF "'$p'" <<<"$out" || fail "two missing paths — every missing path must be named ($p absent): $out"
done
echo "ok: every missing path is named, not just the first"

# Ablation: without the guard's exit, the missing-path case must pass.
ablated="$work/ablated.sh"
grep -v '^ *exit 1$' "$script" >"$ablated"
cmp -s "$script" "$ablated" && fail "ablation — removing 'exit 1' changed nothing"
out="$(run "ablated guard" '*\n!gone/a.yaml\n' "$ablated")" ||
  fail "ablation — the case still fails without the guard, so the guard is not what refuses it: $out"
echo "ok: ablation — the guard's exit is what refuses a missing path"
