#!/usr/bin/env bash
#
# Exercises scripts/check-repository-coverage.sh against hand-written fixtures,
# without touching the network.
#
# The cases that matter are the ones where a wrong answer is silent: an
# undeclared repository the check misses, and a listing that cannot see the
# whole org reported as a clean pass.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo_root/scripts/check-repository-coverage.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "repository-coverage test: $*" >&2
  exit 1
}

# The check refuses to run on a render with fewer than ten repositories.
readonly FIXTURE_REPOS=10

# Writes a render declaring fixture-repo-1..10 (fixture-repo-10 archived) and a
# live listing that matches it, plus the exempt `actions` repository.
build_fixture() {
  local dir="$1" i archived
  mkdir -p "$dir"
  : >"$dir/render.yaml"
  : >"$dir/live.txt"
  for ((i = 1; i <= FIXTURE_REPOS; i++)); do
    archived=false
    ((i == FIXTURE_REPOS)) && archived=true
    cat >>"$dir/render.yaml" <<EOF
---
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: Repository
metadata:
  name: fixture-repo-$i
spec:
  forProvider:
    name: fixture-repo-$i
    archived: $archived
EOF
    echo "fixture-repo-$i $archived" >>"$dir/live.txt"
  done
  # A non-Repository kind naming a repository must not count as a declaration.
  cat >>"$dir/render.yaml" <<'EOF'
---
apiVersion: team.github.m.upbound.io/v1alpha1
kind: TeamRepository
metadata:
  name: admins-labels-only
spec:
  forProvider:
    repository: labels-only
EOF
  echo "actions false" >>"$dir/live.txt"
}

# Runs the check on a fixture; sets $out and $rc.
run_check() {
  local dir="$1"
  set +e
  out="$(REPOSITORY_COVERAGE_RENDER="$dir/render.yaml" REPOSITORY_COVERAGE_LIVE="$dir/live.txt" \
    bash "$check" 2>&1)"
  rc=$?
  set -e
}

# 1. Everything declared: pass.
build_fixture "$work/clean"
run_check "$work/clean"
[[ "$rc" -eq 0 ]] || fail "clean fixture should pass, got rc=$rc: $out"
[[ "$out" == *"all 10 live repositories are declared"* ]] ||
  fail "clean fixture should report the live count, got: $out"

# 2. A live repository deploy/ does not declare: finding.
build_fixture "$work/undeclared"
echo "brand-new false" >>"$work/undeclared/live.txt"
run_check "$work/undeclared"
[[ "$rc" -eq 1 ]] || fail "an undeclared repository should fail with 1, got rc=$rc: $out"
[[ "$out" == *"UNDECLARED brand-new"* ]] || fail "the undeclared repository should be named, got: $out"

# 3. Named only by a non-Repository kind is still undeclared.
build_fixture "$work/labels-only"
echo "labels-only false" >>"$work/labels-only/live.txt"
run_check "$work/labels-only"
[[ "$rc" -eq 1 && "$out" == *"UNDECLARED labels-only"* ]] ||
  fail "a repository with only a team grant should count as undeclared, got rc=$rc: $out"

# 4. An archived live repository is out of scope.
build_fixture "$work/archived"
echo "old-thing true" >>"$work/archived/live.txt"
run_check "$work/archived"
[[ "$rc" -eq 0 ]] || fail "an archived undeclared repository should not fail, got rc=$rc: $out"

# 5. The listing cannot see a declared repository (e.g. a private one): fail
#    closed, because it could be missing undeclared ones too.
build_fixture "$work/unseen"
grep -v '^fixture-repo-3 ' "$work/unseen/live.txt" >"$work/unseen/live.tmp"
mv "$work/unseen/live.tmp" "$work/unseen/live.txt"
echo "brand-new false" >>"$work/unseen/live.txt"
run_check "$work/unseen"
[[ "$rc" -eq 2 ]] || fail "a listing that misses a declared repository should fail closed with 2, got rc=$rc: $out"
[[ "$out" == *"UNSEEN fixture-repo-3"* ]] || fail "the unseen repository should be named, got: $out"

# 6. An exemption that no longer applies: finding.
build_fixture "$work/stale"
grep -v '^actions ' "$work/stale/live.txt" >"$work/stale/live.tmp"
mv "$work/stale/live.tmp" "$work/stale/live.txt"
run_check "$work/stale"
[[ "$rc" -eq 1 && "$out" == *"STALE-EXEMPTION actions"* ]] ||
  fail "an exemption for a repository that is gone should be reported stale, got rc=$rc: $out"

# 7. An empty listing: fail closed.
build_fixture "$work/empty"
: >"$work/empty/live.txt"
run_check "$work/empty"
[[ "$rc" -eq 2 ]] || fail "an empty live listing should fail closed with 2, got rc=$rc: $out"

# 8. A collapsed render: fail closed, never a vacuous pass.
build_fixture "$work/collapsed"
cat >"$work/collapsed/render.yaml" <<'EOF'
---
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: Repository
metadata:
  name: only-one
spec:
  forProvider:
    name: only-one
EOF
run_check "$work/collapsed"
[[ "$rc" -eq 2 ]] || fail "a render with too few repositories should fail closed with 2, got rc=$rc: $out"

echo "repository-coverage test: all cases passed"
