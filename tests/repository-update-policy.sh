#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render="$(mktemp)"
trap 'rm -f "$render"' EXIT

fail() {
  echo "repository-update-policy test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

kubectl kustomize "$repo_root/deploy" >"$render" ||
  fail "kubectl kustomize deploy/ failed"
[[ -s "$render" ]] || fail "rendered output is empty"

# Active (non-archived) repositories only. Archived repos live in
# deploy/archived-repositories/, get no shared patch, and are read-only for
# settings, so the update contract below does not apply to them.
active_repositories="$(
  yq -N '
    select(.kind == "Repository" and .spec.forProvider.archived != true) |
    .metadata.name
  ' "$render"
)"
active_count="$(printf '%s\n' "$active_repositories" | grep -c . || true)"
[[ "$active_count" -ge 10 ]] ||
  fail "active Repository set collapsed to $active_count entries"

# LateInitialize copies live-only values into forProvider, and everything in
# forProvider is sent on every update PATCH. Delete would let a prune destroy a
# real repository. Neither may appear; a repository parked on Observe alone is
# allowed, because a resource that never writes cannot send a bad payload.
unsafe_policies="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (
        (.spec.managementPolicies | contains(["LateInitialize"])) or
        (.spec.managementPolicies | contains(["Delete"])) or
        ((.spec.managementPolicies | contains(["Observe"])) != true)
      )
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$unsafe_policies" ]] ||
  fail "active Repository resources must be Observe-based without LateInitialize or Delete: $unsafe_policies"

# The org enforces commit signoff. GitHub rejects the entire PATCH with 422
# whenever this field appears in a repository update, whatever value it carries,
# so it must never reach forProvider.
update_payload_signoff="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (.spec.forProvider | has("webCommitSignoffRequired"))
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$update_payload_signoff" ]] ||
  fail "org-controlled signoff remains in forProvider: $update_payload_signoff"

# Keeping it create-only is what preserves the secure default for new repos.
missing_create_signoff="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      .spec.initProvider.webCommitSignoffRequired != true
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$missing_create_signoff" ]] ||
  fail "create-only signoff is missing from initProvider: $missing_create_signoff"

echo "repository-update-policy: OK — $active_count active repositories keep signoff create-only"
