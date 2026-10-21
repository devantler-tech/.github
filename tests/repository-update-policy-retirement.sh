#!/usr/bin/env bash
# Exercise the actual policy guard after the last archived repository is removed.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
kubectl kustomize "$root/deploy" >"$work/current.yaml"
yq 'select(.kind != "Repository" or .spec.forProvider.archived != true)' \
  "$work/current.yaml" >"$work/active.yaml"
cat >"$work/bin/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && $1 == kustomize && $2 == "$POLICY_TEST_ROOT/deploy" ]] || exit 90
[[ ${POLICY_TEST_RENDER_FAIL:-false} != true ]] || exit 91
cat "$POLICY_TEST_RENDER"
KUBECTL
chmod +x "$work/bin/kubectl"
export POLICY_TEST_ROOT="$root"
check() {
  local render=$1 expected=$2 reason=$3 status=0
  PATH="$work/bin:$PATH" POLICY_TEST_RENDER="$render" \
    bash "$root/tests/repository-update-policy.sh" >"$work/result" 2>&1 || status=$?
  [[ $status == "$expected" ]] || {
    printf 'FAIL: %s expected exit %s, got %s\n' "$reason" "$expected" "$status" >&2
    cat "$work/result" >&2
    exit 1
  }
  if [[ $expected != 0 ]]; then
    grep -F "$reason" "$work/result" >/dev/null || {
      cat "$work/result" >&2
      exit 1
    }
  fi
  printf 'PASS: %s\n' "$reason"
}
check "$work/active.yaml" 0 'the last archived repository may be retired'
fixture() {
  cp "$work/active.yaml" "$work/case.yaml"
  printf '\n---\nkind: Repository\nmetadata:\n  name: fixture-archived\nspec:\n  forProvider:\n    archived: true\n  managementPolicies: %s\n' "$1" >>"$work/case.yaml"
}
fixture '["Observe"]'
check "$work/case.yaml" 0 'one observe-only archived repository is safe'
for policies in '["Observe","Update"]' '["Observe","LateInitialize"]' \
  '["Observe","Create"]' '["Observe","Delete"]' '["*"]' '[]' 'null'; do
  fixture "$policies"
  check "$work/case.yaml" 1 'archived Repository resources must be Observe-only'
done
POLICY_TEST_RENDER_FAIL=true check "$work/active.yaml" 1 'kubectl kustomize deploy/ failed'
printf 'PASS: retirement preserves archived-policy refusals and render failure handling\n'
