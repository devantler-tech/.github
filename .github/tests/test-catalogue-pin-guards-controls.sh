#!/usr/bin/env bash
# Mutate only YAML data in disposable copies; never execute a changed remote pin.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$work/fixture"
baseline="$work/baseline"
mkdir -p "$baseline/actions/dependency-review"
cp -R "$root/.github" "$root/.scripts" "$baseline/"
cp "$root/actions/dependency-review/action.yaml" "$baseline/actions/dependency-review/"
cp "$root/README.md" "$baseline/"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
reset_fixture() {
  rm -rf "$fixture"
  cp -R "$baseline" "$fixture"
}
run_guard() {
  (
    cd "$fixture"
    case "$1" in
    author) bash .github/tests/test-enable-auto-merge-author-gate.sh ;;
    zizmor) bash .github/tests/test-zizmor-routing.sh ;;
    world) bash .github/tests/test-world-at-ruin-required-regressions.sh ;;
    dependency) bash .github/tests/test-dependency-review-comments.sh ;;
    parity) bash .github/tests/test-catalogue-tool-pin-parity.sh ;;
    *) exit 99 ;;
    esac
  ) >"$work/output" 2>&1
}
accept() {
  local mode="$1" file="$2" expression="$3"
  reset_fixture
  yq -i "$expression" "$fixture/$file"
  run_guard "$mode" || fail "coordinated update rejected: $(cat "$work/output")"
  echo "PASS: $mode accepts a complete pin update without editing its guard"
}
reject() {
  local mode="$1" file="$2" expression="$3" diagnostic="$4"
  reset_fixture
  yq -i "$expression" "$fixture/$file"
  if run_guard "$mode"; then fail "$mode accepted $expression"; fi
  grep -Fq "$diagnostic" "$work/output" || fail "$mode failed for another reason: $(cat "$work/output")"
  echo "PASS: $mode rejects the intended pin or role regression"
}
sha=0123456789abcdef0123456789abcdef01234567
for mode in author zizmor world dependency parity; do
  reset_fixture
  run_guard "$mode" || fail "healthy $mode failed: $(cat "$work/output")"
done
accept author .github/workflows/enable-auto-merge.yaml ".jobs.eligibility.steps[0].uses = \"step-security/harden-runner@$sha\""
accept author .github/workflows/enable-auto-merge.yaml "(.jobs.disarm-untrusted-update.steps[] | select(.name == \"📥 Checkout trusted disarm script\")).uses = \"actions/checkout@$sha\""
accept zizmor .github/workflows/scan-for-workflow-vulnerabilities.yaml ".jobs.eligibility.steps[0].uses = \"step-security/harden-runner@$sha\""
accept world .github/workflows/world-at-ruin-required-regressions.yaml ".jobs.eligibility.steps[0].uses = \"step-security/harden-runner@$sha\""
accept dependency actions/dependency-review/action.yaml "(.runs.steps[] | select(.id == \"review\")).uses = \"actions/dependency-review-action@$sha\""

# Independent production and fixture files must move together, without changing
# any guard literal. Old SHA comments remain in each copied YAML.
for family in golangci megalinter version; do
  reset_fixture
  case "$family" in
  golangci)
    yq -i "(.jobs.golangci-lint.steps[] | select(.id == \"golangci-lint\")).uses = \"golangci/golangci-lint-action@$sha\"" "$fixture/.github/workflows/validate-go-project.yaml"
    yq -i "(.jobs.test-validate-go-lint-blocks.steps[] | select(.id == \"lint\")).uses = \"golangci/golangci-lint-action@$sha\"" "$fixture/.github/workflows/ci.yaml"
    ;;
  megalinter)
    for gate in validate-go-project lint; do
      yq -i "(.jobs.lint.steps[] | select(.id == \"ml\")).uses = \"oxsecurity/megalinter/flavors/go@$sha\"" "$fixture/.github/workflows/$gate.yaml"
    done
    yq -i "(.jobs.test-lint-blocks.steps[] | select(.id == \"ml\")).uses = \"oxsecurity/megalinter/flavors/go@$sha\"" "$fixture/.github/workflows/ci.yaml"
    ;;
  version)
    yq -i '(.jobs.golangci-lint.steps[] | select(.id == "golangci-lint")).with.version = "v99.0.0"' "$fixture/.github/workflows/validate-go-project.yaml"
    yq -i '(.jobs.test-validate-go-lint-blocks.steps[] | select(.id == "lint")).with.version = "v99.0.0"' "$fixture/.github/workflows/ci.yaml"
    ;;
  esac
  run_guard parity || fail "coordinated $family update rejected: $(cat "$work/output")"
  echo "PASS: independent $family sources move together"
done
for bad in 'step-security/harden-runner@v2' 'step-security/harden-runner@0123456' "other/harden-runner@$sha"; do
  reject author .github/workflows/enable-auto-merge.yaml ".jobs.eligibility.steps[0].uses = \"$bad\"" 'eligibility must begin'
  reject zizmor .github/workflows/scan-for-workflow-vulnerabilities.yaml ".jobs.eligibility.steps[0].uses = \"$bad\"" 'must begin'
  reject world .github/workflows/world-at-ruin-required-regressions.yaml ".jobs.eligibility.steps[0].uses = \"$bad\"" 'first eligibility step'
done
reject author .github/workflows/enable-auto-merge.yaml '(.jobs.disarm-untrusted-update.steps[] | select(.name == "📥 Checkout trusted disarm script")).uses = "actions/checkout@main"' 'trusted base/called-workflow'
reject author .github/workflows/enable-auto-merge.yaml '(.jobs.disarm-untrusted-update.steps[] | select(.name == "📥 Checkout trusted disarm script")).with.persist-credentials = true' 'trusted base/called-workflow'
reject author .github/workflows/enable-auto-merge.yaml '.jobs.disarm-untrusted-update.steps += [.jobs.disarm-untrusted-update.steps[] | select(.name == "📥 Checkout trusted disarm script")]' 'trusted base/called-workflow'
reject dependency actions/dependency-review/action.yaml '(.runs.steps[] | select(.id == "review")).uses = "actions/dependency-review-action@main"' 'forward repo-token'
reject dependency actions/dependency-review/action.yaml '(.runs.steps[] | select(.id == "review")).with.repo-token = "wrong"' 'forward repo-token'
reject dependency actions/dependency-review/action.yaml '.runs.steps += [.runs.steps[] | select(.id == "review")]' 'forward repo-token'
reject dependency actions/dependency-review/action.yaml 'del(.runs.steps[] | select(.id == "review"))' 'forward repo-token'
for file in validate-go-project ci; do
  job=golangci-lint id=golangci-lint
  [[ "$file" != ci ]] || {
    job=test-validate-go-lint-blocks
    id=lint
  }
  reject parity ".github/workflows/$file.yaml" "(.jobs.$job.steps[] | select(.id == \"$id\")).uses = \"golangci/golangci-lint-action@$sha\"" 'golangci action pins differ'
  reject parity ".github/workflows/$file.yaml" "(.jobs.$job.steps[] | select(.id == \"$id\")).uses = \"golangci/golangci-lint-action@v9\"" 'exactly one full-SHA'
  reject parity ".github/workflows/$file.yaml" "(.jobs.$job.steps[] | select(.id == \"$id\")).with.version = \"\"" 'versions differ or are missing'
  reject parity ".github/workflows/$file.yaml" ".jobs.$job.steps += [.jobs.$job.steps[] | select(.id == \"$id\")]" 'exactly one full-SHA'
done
for file in validate-go-project lint ci; do
  job=lint
  [[ "$file" != ci ]] || job=test-lint-blocks
  reject parity ".github/workflows/$file.yaml" "(.jobs.$job.steps[] | select(.id == \"ml\")).uses = \"oxsecurity/megalinter/flavors/go@$sha\"" 'different MegaLinter pins'
  reject parity ".github/workflows/$file.yaml" "del(.jobs.$job.steps[] | select(.id == \"ml\"))" 'exactly one full-SHA'
  reject parity ".github/workflows/$file.yaml" ".jobs.$job.steps += [.jobs.$job.steps[] | select(.id == \"ml\")]" 'exactly one full-SHA'
done
reject parity .github/workflows/validate-go-project.yaml '(.jobs.test.steps[] | select(.name == "🧪 Test")).run = "# go test ./...\ntrue"' 'production test role'
reject parity .github/workflows/ci.yaml '(.jobs.test-validate-go-test-blocks.steps[] | select(.id == "gotest")).run = "# go test ./...\ntrue"' 'real test command'
echo 'PASS: pin updates remain maintainable; identity, full SHA, role, credential and independent-fixture checks fail closed'
