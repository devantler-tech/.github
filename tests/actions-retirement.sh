#!/usr/bin/env bash
# Keep retirement #240 from accidentally restoring managed resources for the deleted catalogue.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$root/scripts/validate-actions-retirement.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Fail at the first incorrect observation rather than accepting a partial inventory.
fail() { printf 'actions-retirement test: %s\n' "$*" >&2; exit 1; }
# Keep withdrawn, still-managed and unreadable outcomes distinct for every control.
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
# GitHub repository identifiers are case-insensitive in both provider phases.
for field in forProvider.name initProvider.name forProvider.repository initProvider.repository; do
  FIELD="$field" yq '.kind = "Repository" | .spec |= setpath(strenv(FIELD) | split("."); "AcTiOnS")' \
    "$work/clean.yaml" >"$work/mixed.yaml"
  check 1 "$work/mixed.yaml"
done
# An adopted resource can target Actions through external identity even when its
# desired name differs; Observe-only management must still prevent retirement.
yq '.kind = "Repository" | .metadata.annotations."crossplane.io/external-name" = "AcTiOnS" |
  .spec.forProvider.name = "different-desired-name" | .spec.managementPolicies = ["Observe"]' \
  "$work/clean.yaml" >"$work/adopted.yaml"
check 1 "$work/adopted.yaml"
# Import identities remain authoritative even when Observe-only resources omit
# both desired-state provider blocks. Each retired resource kind needs coverage.
for kind in Repository IssueLabels RepositoryPermissions; do
  KIND="$kind" yq '.kind = strenv(KIND) | .spec.forProvider = {} |
    .spec.managementPolicies = ["Observe"] |
    .metadata.annotations."crossplane.io/external-name" = "AcTiOnS"' \
    "$work/clean.yaml" >"$work/imported.yaml"
  check 1 "$work/imported.yaml"
  grep -Fq 'retired catalogue is still managed' "$work/err" ||
    fail "$kind external identity was refused for the wrong reason"
  yq '.metadata.annotations."crossplane.io/external-name" = ".github"' \
    "$work/imported.yaml" >"$work/other-import.yaml"
  check 0 "$work/other-import.yaml"
done
# TeamRepository's provider identity is team ID/slug followed by the repository.
for identity in 12345:AcTiOnS maintainers:AcTiOnS; do
  IDENTITY="$identity" yq '.kind = "TeamRepository" | .spec.forProvider = {} |
    .spec.managementPolicies = ["Observe"] |
    .metadata.annotations."crossplane.io/external-name" = strenv(IDENTITY)' \
    "$work/clean.yaml" >"$work/imported-team.yaml"
  check 1 "$work/imported-team.yaml"
done
for identity in 12345:.github actions:.github; do
  IDENTITY="$identity" yq '.metadata.annotations."crossplane.io/external-name" = strenv(IDENTITY)' \
    "$work/imported-team.yaml" >"$work/other-team.yaml"
  check 0 "$work/other-team.yaml"
done
# Syntactically valid but truncated managed resources are incomplete observations,
# not evidence that a repository is no longer targeted. Empty provider objects
# remain valid for the Observe-only import controls above.
for kind in Repository IssueLabels RepositoryPermissions TeamRepository; do
  for mutation in 'del(.spec)' '.spec = null' '.spec = []' '.spec = "truncated"' \
    'del(.spec.forProvider)' '.spec.forProvider = null' '.spec.forProvider = []' \
    '.spec.forProvider = "truncated"'; do
    KIND="$kind" yq '.kind = strenv(KIND)' "$work/clean.yaml" |
      yq "$mutation" >"$work/truncated.yaml"
    check 2 "$work/truncated.yaml"
  done
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
printf 'actions-retirement: OK — rendered withdrawal, case/adopted identities and failed reads\n'
