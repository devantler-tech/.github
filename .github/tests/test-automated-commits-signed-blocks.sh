#!/usr/bin/env bash
# Fixture counterpart to test-automated-commits-signed.sh.
#
# The catalogue now delegates commits to its signing API workflow. Legacy
# create-pull-request fixtures still guard against unsafe reintroduction.
# This test drives the same guard over inputs it must ACCEPT and inputs it must REJECT, so
# each half is proven independently of the repository's current contents.
#
# The reject cases are one per way the token check has been observed to fail open or is
# expected to. `reject-pat-beside-approved` and `reject-bracketed-secret` are the two that
# actually did: an unrecognised reference riding alongside an approved one, which a scan
# that extracts recognised fragments cannot see. The accept cases are the positive controls
# — without them a guard that rejected everything would pass this test.

set -euo pipefail

guard="${1:-.github/tests/test-automated-commits-signed.sh}"
fixture_root="${2:-.github/tests/automated-commits-signed-fixtures}"

[[ -f "$guard" ]] || { echo "::error::guard $guard is missing"; exit 1; }
[[ -d "$fixture_root" ]] || { echo "::error::fixture root $fixture_root is missing"; exit 1; }
guard="$(cd "$(dirname "$guard")" && pwd)/$(basename "$guard")"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

status=0
accepted=0
rejected=0

expect() {
  local name=$1 want=$2 dir="$fixture_root/$1" out rc=0
  if [[ ! -d "$dir" ]]; then
    echo "::error::fixture $name is missing — this case cannot prove anything"
    status=1
    return
  fi
  out="$(bash "$guard" "$dir" 2>&1)" || rc=$?

  if [[ "$want" == accept ]]; then
    accepted=$((accepted + 1))
    if ((rc != 0)); then
      echo "::error::$name must be ACCEPTED but the guard rejected it (rc=$rc)"
      printf '        %s\n' "$out"
      status=1
    fi
  else
    rejected=$((rejected + 1))
    if ((rc == 0)); then
      echo "::error::$name must be REJECTED but the guard passed it — this is a fail-open"
      printf '        %s\n' "$out"
      status=1
    fi
  fi
}

# Positive controls: a guard that rejects everything fails here.
expect accept-default-token        accept
expect accept-token-absent         accept
expect accept-app-token-fallback   accept

# Token source is not signing-capable.
expect reject-pat                  reject
expect reject-branch-token-pat     reject

# The measured fail-open: an unrecognised reference beside an approved one.
expect reject-pat-beside-approved  reject
expect reject-bracketed-secret     reject

# Nothing resolvable to vet at all.
expect reject-literal              reject
expect reject-glued-literal        reject
expect reject-workflow-input       reject

# Trust must come from the step's `uses`, never from its id.
expect reject-impostor-app-step    reject

# The two vacuity controls inside the guard itself.
expect reject-unsigned             reject
expect reject-no-producer          reject

# Exercise the retained production mechanism without a legacy action present.
# Dropping its API mutation or signature proof must still be rejected.
api_root="$(mktemp -d)"
trap 'rm -rf "$api_root"' EXIT
mkdir -p "$api_root/.github/workflows" "$api_root/.github/actions/prepare-fixes"
cp "$repo_root/.github/actions/prepare-fixes/action.yaml" "$api_root/.github/actions/prepare-fixes/action.yaml"
api_fixture() {
  cp "$repo_root/.github/workflows/validate-go-project.yaml" "$api_root/.github/workflows/validate-go-project.yaml"
  cp "$repo_root/.github/workflows/apply-signed-fixes.yaml" "$api_root/.github/workflows/apply-signed-fixes.yaml"
}
api_expect() {
  local label="$1" want="$2" diagnostic="${3:-}" out rc=0
  out="$(cd "$api_root" && bash "$guard" 2>&1)" || rc=$?
  if [[ "$want" == accept ]]; then
    accepted=$((accepted + 1))
    if ((rc != 0)); then
      printf '::error::%s must accept the retained signing API producer: %s\n' "$label" "$out"
      exit 1
    fi
  else
    rejected=$((rejected + 1))
    if ((rc == 0)) || ! grep -Fq "$diagnostic" <<<"$out"; then
      printf '::error::%s must reject for %s; got: %s\n' "$label" "$diagnostic" "$out"
      exit 1
    fi
  fi
}
api_fixture
api_expect api-only accept
api_fixture
yq -i '(.jobs.apply-fixes.steps[] | select(.name == "📤 Commit the applied fixes").run) |= sub("createCommitOnBranch\\(input:"; "unsignedCommit(input:")' "$api_root/.github/workflows/apply-signed-fixes.yaml"
api_expect missing-api-mutation reject 'must create its commit with the createCommitOnBranch API'
api_fixture
yq -i '(.jobs.apply-fixes.steps[] | select(has("run")).run) |= sub("commit.verification.verified"; "commit.verification.assumed")' "$api_root/.github/workflows/apply-signed-fixes.yaml"
api_expect missing-signature-proof reject 'must verify the created commit reports verified=true'
api_fixture
yq -i '.jobs.unsigned.steps = [{"run": "git commit -m unsigned"}]' "$api_root/.github/workflows/validate-go-project.yaml"
api_expect local-unsigned-commit reject "must not run 'git commit' or 'git push'"
api_fixture
cat > "$api_root/.github/workflows/unsigned.yaml" <<'YAML'
jobs:
  unsigned:
    steps:
      - uses: stefanzweifel/git-auto-commit-action@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YAML
api_expect unsigned-action-in-another-workflow reject 'git-auto-commit-action cannot produce a signed commit'

# Guard the guard: a miscounted table silently shrinks coverage.
if ((accepted < 4 || rejected < 14)); then
  echo "::error::coverage shrank — expected at least 4 accept and 14 reject cases, ran $accepted and $rejected"
  status=1
fi

if ((status == 0)); then
  echo "PASS: the signing guard accepted all $accepted approved fixtures and rejected all $rejected prohibited ones"
fi
exit "$status"
