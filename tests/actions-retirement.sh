#!/usr/bin/env bash
# Keep retirement #240 from accidentally restoring managed resources for the deleted catalogue.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$root/scripts/validate-actions-retirement.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'actions-retirement test: %s\n' "$*" >&2; exit 1; }
check() {
  local expected="$1" input="$2" rc=0
  bash "$validator" "$input" >"$work/out" 2>"$work/err" || rc=$?
  [[ "$rc" == "$expected" ]] || fail "expected $expected, got $rc"
}
cat >"$work/clean.yaml" <<'YAML'
apiVersion: actions.github.m.upbound.io/v1alpha1
kind: RepositoryPermissions
metadata:
  name: maintained-catalogue
spec:
  forProvider:
    repository: .github
YAML
check 0 "$work/clean.yaml"
grep -Fq 'no managed resources target the retired catalogue' "$work/out" ||
  fail 'clean control did not examine the render'
for kind in Repository IssueLabels TeamRepository RepositoryPermissions; do
  cp "$work/clean.yaml" "$work/retired.yaml"
  cat >>"$work/retired.yaml" <<YAML
---
apiVersion: repo.github.m.upbound.io/v1alpha1
kind: $kind
metadata:
  name: restored-retirement
spec:
  forProvider:
    name: actions
    repository: actions
YAML
  check 1 "$work/retired.yaml"
  grep -Fq 'retired catalogue is still managed' "$work/err" ||
    fail "$kind was refused for the wrong reason"
done
printf 'not: [valid\n' >"$work/invalid.yaml"
check 2 "$work/invalid.yaml"
: >"$work/empty.yaml"
check 2 "$work/empty.yaml"
check 2 "$work/missing.yaml"
# A parser emitting plausible partial data and then failing cannot establish withdrawal.
real_yq="$(command -v yq)"
mkdir "$work/bin"
cat >"$work/bin/yq" <<'SH'
#!/usr/bin/env bash
printf '{"kind":"Repository","metadata":{"name":"safe"},"spec":{"forProvider":{"name":"safe"}}}\n'
exit 42
SH
chmod +x "$work/bin/yq"
PATH="$work/bin:$PATH" check 2 "$work/clean.yaml"
[[ -x "$real_yq" ]] || fail 'real parser is unavailable'
# The actual rendered desired state, not filenames alone, must establish withdrawal.
kubectl kustomize "$root/deploy" >"$work/actual.yaml"
check 0 "$work/actual.yaml"
printf 'actions-retirement: OK — rendered withdrawal, four re-add controls and failed reads\n'
