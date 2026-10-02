#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
guard="$root/.github/tests/test-go-memory-limit.sh"
bash "$guard" >"$work/output" 2>&1 || fail "healthy memory override failed: $(cat "$work/output")"
reject() {
  local label="$1" expression="$2"
  cp "$root/.github/workflows/validate-go-project.yaml" "$work/workflow.yaml"
  yq -i "$expression" "$work/workflow.yaml"
  if bash "$guard" "$work/workflow.yaml" >"$work/output" 2>&1; then
    fail "$label was accepted"
  fi
  grep -q 'Go memory override interface or preflight wiring' "$work/output" ||
    fail "$label failed for another reason: $(cat "$work/output")"
  echo "PASS: $label is rejected"
}
reject 'missing override input' 'del(.on.workflow_call.inputs.go-memory-limit)'
reject 'missing default' 'del(.on.workflow_call.inputs.go-memory-limit.default)'
reject 'over-ceiling default' '.on.workflow_call.inputs.go-memory-limit.default = "12GiB"'
reject 'empty candidate' '.jobs.deadcode.env.GO_MEMORY_LIMIT = ""'
reject 'unknown candidate expression' '.jobs.govulncheck.env.GO_MEMORY_LIMIT = "unknown"'
reject 'missing cap' 'del(.jobs.govulncheck.env.GOMEMLIMIT)'
reject 'missing preflight' 'del(.jobs.deadcode.steps[] | select(.id == "memory-limit"))'
reject 'disabled preflight' '(.jobs.deadcode.steps[] | select(.id == "memory-limit")).if = "false"'
reject 'ignored preflight failure' '(.jobs.govulncheck.steps[] | select(.id == "memory-limit")).continue-on-error = true'
reject 'preflight after Go setup' '.jobs.deadcode.steps |= map(select(.id != "memory-limit")) + map(select(.id == "memory-limit"))'
reject 'helper from mutable ref' '(.jobs.deadcode.steps[] | select(.with.path == ".devantler-tech-actions")).with.ref = "main"'
reject 'helper from another repository' '(.jobs.govulncheck.steps[] | select(.with.path == ".devantler-tech-actions")).with.repository = "unknown"'
reject 'persisted helper credentials' '(.jobs.deadcode.steps[] | select(.with.path == ".devantler-tech-actions")).with.persist-credentials = true'
reject 'new capped job without validation' '.jobs.extra = {"env":{"GOMEMLIMIT":"8GiB"},"steps":[]}'

# Behavioral controls run a copy of the shipped guard/preflight, so a parser that
# accepts everything or a preflight that never exports cannot pass on shape alone.
mkdir -p "$work/fixture/.github/tests" "$work/fixture/.github/scripts" "$work/fixture/.github/workflows"
cp "$guard" "$work/fixture/.github/tests/"
cp "$root/.github/workflows/validate-go-project.yaml" "$work/fixture/.github/workflows/"
printf '#!/usr/bin/env bash\nprintf "0\\n"\n' >"$work/fixture/.github/scripts/validate-go-memory-limit.sh"
if bash "$work/fixture/.github/tests/test-go-memory-limit.sh" >"$work/output" 2>&1; then
  fail 'accept-everything parser was accepted'
fi
grep -q 'accepted unsafe input' "$work/output" || fail 'parser control failed for another reason'
cp "$root/.github/scripts/validate-go-memory-limit.sh" "$work/fixture/.github/scripts/"
cat >"$work/missing-export.yq" <<'YQ'
(.jobs.deadcode.steps[] | select(.id == "memory-limit")).run = "bash \"$GITHUB_WORKSPACE/.devantler-tech-actions/.github/scripts/validate-go-memory-limit.sh\" \"$GO_MEMORY_LIMIT\" 8\n# $GITHUB_ENV"
YQ
yq -i --from-file "$work/missing-export.yq" "$work/fixture/.github/workflows/validate-go-project.yaml"
if bash "$work/fixture/.github/tests/test-go-memory-limit.sh" >"$work/output" 2>&1; then
  fail 'missing runtime export was accepted'
fi
grep -q 'did not export exactly the validated limit' "$work/output" || fail 'export control failed for another reason'
cp "$root/.github/workflows/validate-go-project.yaml" "$work/fixture/.github/workflows/"
yq -i '(.jobs.deadcode.steps[] | select(.id == "memory-limit")).run |= sub(" 8"; " 9")' "$work/fixture/.github/workflows/validate-go-project.yaml"
if bash "$work/fixture/.github/tests/test-go-memory-limit.sh" >"$work/output" 2>&1; then
  fail 'raised runtime ceiling was accepted'
fi
grep -q 'accepted unsafe input' "$work/output" || fail 'ceiling control failed for another reason'
echo 'PASS: 14 independent wiring controls and 3 runtime controls'
