#!/usr/bin/env bash

# Pins how the two publish workflows sign what they push (#260): every cosign signature
# targets a digest reference, and publish-app.yaml signs the digest its own `flux push`
# reported. A signature made by tag covers whatever the tag points at when cosign resolves
# it, so a tag moved by an overlapping release or another writer would be signed with bytes
# this run did not publish, and consumers verify that signature.
#
# The behavioural half runs each signing step EXTRACTED FROM ITS WORKFLOW against stub
# `flux`, `cosign` and `docker` binaries, so the assertions cannot drift from what ships:
#   1. publish-app signs ARTIFACT@<the digest flux push reported>, and the image by digest.
#   2. publish-app fails before signing anything when the push reports no digest.
#   3. publish-manifests signs the manifests artifact by digest.
#   4. In every run, EVERY cosign target is a digest reference — not merely "not VERSION".
# The structural half requires every `cosign sign` line in both workflows to end in a
# digest reference, so a literal tag or another variable cannot slip in.

set -euo pipefail

step_name="📦 Push & sign manifests artifact"
signing_workflows=(
  ".github/workflows/publish-app.yaml"
  ".github/workflows/publish-manifests.yaml"
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

pushed_digest="sha256:$(printf 'a%.0s' $(seq 1 64))"
resolved_digest="sha256:$(printf 'c%.0s' $(seq 1 64))"
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
cat >"$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$CALLS"
printf '%s\n' "$RESOLVED_DIGEST"
EOF
chmod +x "$scratch/bin/flux" "$scratch/bin/cosign" "$scratch/bin/docker"

extract_step() { # <workflow> <out>
  [[ -f "$1" ]] || fail "missing workflow: $1"
  STEP_NAME="$step_name" yq -r '.jobs[].steps[] | select(.name == strenv(STEP_NAME)) | .run' \
    "$1" >"$2"
  [[ -s "$2" ]] || fail "$1 has no '$step_name' step to exercise"
}

run_step() { # <script> <flux push json>
  : >"$scratch/calls"
  PATH="$scratch/bin:$PATH" CALLS="$scratch/calls" FLUX_PUSH_JSON="$2" \
    RESOLVED_DIGEST="$resolved_digest" \
    REGISTRY=ghcr.io IMAGE_NAME=devantler-tech/app IMAGE=ghcr.io/devantler-tech/app \
    OCI_NAME=devantler-tech/app DIGEST="$image_digest" DEPLOY_PATH=deploy REF_NAME=v1.2.3 \
    SHA=0123456789abcdef SERVER_URL=https://github.com REPOSITORY=devantler-tech/app \
    ACTOR=bot GH_TOKEN=stub-not-a-secret \
    bash "$1" >"$scratch/out" 2>&1
}

signed() { # <exact cosign line> <label>
  grep -qxF "$1" "$scratch/calls" || fail "$2; calls: $(cat "$scratch/calls")"
}

only_digest_targets() { # <label>
  grep -E '^cosign sign' "$scratch/calls" >"$scratch/signs" || fail "$1 made no cosign signature"
  if grep -vqE '@sha256:[0-9a-f]{64}$' "$scratch/signs"; then
    fail "$1 signs a target that is not a digest reference; calls: $(cat "$scratch/calls")"
  fi
}

push_json="{\"repository\":\"ghcr.io/devantler-tech/app/manifests\",\"tag\":\"1.2.3\",\"digest\":\"$pushed_digest\"}"

# 1. publish-app signs exactly what the push reported.
extract_step .github/workflows/publish-app.yaml "$scratch/publish-app.sh"
run_step "$scratch/publish-app.sh" "$push_json" ||
  fail "publish-app step failed on a normal push: $(cat "$scratch/out")"
signed "cosign sign --yes ghcr.io/devantler-tech/app/manifests@$pushed_digest" \
  "publish-app did not sign the manifests artifact by the pushed digest"
signed "cosign sign --yes ghcr.io/devantler-tech/app@$image_digest" \
  "publish-app did not sign the image by its build digest"
only_digest_targets publish-app
echo "ok   publish-app signs the manifests artifact by the digest flux push reported"

# 2. No digest reported: fail before signing anything.
if run_step "$scratch/publish-app.sh" '{"repository":"ghcr.io/devantler-tech/app/manifests","tag":"1.2.3"}'; then
  fail "publish-app succeeded although flux push reported no digest"
fi
if grep -q '^cosign sign' "$scratch/calls"; then
  fail "publish-app signed something although flux push reported no digest; calls: $(cat "$scratch/calls")"
fi
echo "ok   publish-app fails before signing when the push reports no digest"

# 3. publish-manifests signs by digest.
extract_step .github/workflows/publish-manifests.yaml "$scratch/publish-manifests.sh"
run_step "$scratch/publish-manifests.sh" "$push_json" ||
  fail "publish-manifests step failed on a normal push: $(cat "$scratch/out")"
only_digest_targets publish-manifests
echo "ok   publish-manifests signs only digest references"

# 4. Structural: every cosign sign line in both workflows ends in a digest reference.
for signing in "${signing_workflows[@]}"; do
  grep -nE '^[[:space:]]*cosign sign' "$signing" >"$scratch/lines" ||
    fail "$signing has no cosign sign line — refusing to pass vacuously"
  if grep -vE '@\$\{?[A-Z_]+\}?"?[[:space:]]*$' "$scratch/lines" >"$scratch/bad"; then
    fail "$signing signs a target that is not a digest reference: $(cat "$scratch/bad")"
  fi
done
echo "ok   every cosign sign line in both publish workflows targets a digest reference"
