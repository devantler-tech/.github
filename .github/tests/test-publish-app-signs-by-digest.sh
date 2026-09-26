#!/usr/bin/env bash

# Pins how publish-app.yaml signs its manifests artifact (#260): by the digest its own
# `flux push` reported, never by re-resolving the version tag. A tag moved between the
# push and the signature (an overlapping release, another writer) would otherwise get a
# signature over bytes this run did not publish, and consumers verify that signature.
#
# The behavioural half runs the step script EXTRACTED FROM THE WORKFLOW against stub
# `flux` and `cosign` binaries, so the assertions cannot drift from what ships:
#   1. cosign signs ARTIFACT@<the digest flux reported>, and the image by its digest.
#   2. A push that reports no digest fails the step before anything is signed.
# The structural half refuses any tag-form `cosign sign` in either signing workflow.

set -euo pipefail

workflow=".github/workflows/publish-app.yaml"
step_name="📦 Push & sign manifests artifact"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail "missing workflow: $workflow"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

STEP_NAME="$step_name" yq -r '.jobs[].steps[] | select(.name == strenv(STEP_NAME)) | .run' \
  "$workflow" >"$scratch/step.sh"
[[ -s "$scratch/step.sh" ]] || fail "$workflow has no '$step_name' step to exercise"

pushed_digest="sha256:$(printf 'a%.0s' $(seq 1 64))"
image_digest="sha256:$(printf 'b%.0s' $(seq 1 64))"

mkdir -p "$scratch/bin"
cat >"$scratch/bin/flux" <<'EOF'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$CALLS"
if [[ "$1 $2" == "push artifact" ]]; then
  printf '► pushing artifact\n' >&2
  printf '%s\n' "$FLUX_PUSH_JSON"
fi
EOF
cat >"$scratch/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"$CALLS"
EOF
chmod +x "$scratch/bin/flux" "$scratch/bin/cosign"

run_step() { # <flux push json>
  : >"$scratch/calls"
  PATH="$scratch/bin:$PATH" CALLS="$scratch/calls" FLUX_PUSH_JSON="$1" \
    REGISTRY=ghcr.io IMAGE_NAME=devantler-tech/app IMAGE=ghcr.io/devantler-tech/app \
    DIGEST="$image_digest" DEPLOY_PATH=deploy REF_NAME=v1.2.3 SHA=0123456789abcdef \
    SERVER_URL=https://github.com REPOSITORY=devantler-tech/app ACTOR=bot GH_TOKEN=x \
    bash "$scratch/step.sh" >"$scratch/out" 2>&1
}

# 1. Signs exactly what the push reported.
run_step "{\"repository\":\"ghcr.io/devantler-tech/app/manifests\",\"tag\":\"1.2.3\",\"digest\":\"$pushed_digest\"}" ||
  fail "step failed on a normal push: $(cat "$scratch/out")"
grep -qxF "cosign sign --yes ghcr.io/devantler-tech/app/manifests@$pushed_digest" "$scratch/calls" ||
  fail "manifests artifact was not signed by the pushed digest; calls: $(cat "$scratch/calls")"
grep -qxF "cosign sign --yes ghcr.io/devantler-tech/app@$image_digest" "$scratch/calls" ||
  fail "image was not signed by its build digest; calls: $(cat "$scratch/calls")"
if grep -E '^cosign sign' "$scratch/calls" | grep -vqE '@sha256:[0-9a-f]{64}$'; then
  fail "a cosign signature targets a tag; calls: $(cat "$scratch/calls")"
fi
echo "ok   manifests artifact signed by the digest flux push reported"

# 2. No digest reported: fail before signing anything.
if run_step '{"repository":"ghcr.io/devantler-tech/app/manifests","tag":"1.2.3"}'; then
  fail "step succeeded although flux push reported no digest"
fi
if grep -q '^cosign sign' "$scratch/calls"; then
  fail "step signed something although flux push reported no digest; calls: $(cat "$scratch/calls")"
fi
echo "ok   a push without a digest fails before signing"

# Structural: no signing workflow signs a tag-form reference.
for signing in .github/workflows/publish-app.yaml .github/workflows/publish-manifests.yaml; do
  [[ -f "$signing" ]] || fail "missing workflow: $signing"
  if grep -nE 'cosign sign[^#]*:\$\{?VERSION' "$signing"; then
    fail "$signing signs a tag-form reference; sign by digest instead"
  fi
done
echo "ok   no signing workflow signs a tag-form reference"
