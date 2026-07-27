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
# forProvider is sent on every update PATCH, so LateInitialize is what turns a
# live-only value into part of every future payload. The hazard is that pairing,
# not LateInitialize itself: during Observe-first adoption a repository runs on
# Observe+LateInitialize to mirror live state, sends nothing, and is safe. Delete
# would let a prune destroy a real repository and is never allowed.
unsafe_policies="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (
        (
          (.spec.managementPolicies | contains(["LateInitialize"])) and
          (.spec.managementPolicies | contains(["Update"]))
        ) or
        (.spec.managementPolicies | contains(["Delete"])) or
        ((.spec.managementPolicies | contains(["Observe"])) != true)
      )
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$unsafe_policies" ]] ||
  fail "active Repository resources must not pair Update with LateInitialize, must exclude Delete, and must Observe: $unsafe_policies"

# The org enforces commit signoff, and GitHub rejects the entire PATCH with 422
# whenever this field appears in a repository update — measured against the live
# API, sending the field at its own current value of true still fails. The
# Terraform provider only omits it from the payload when it is left unconfigured,
# and upjet feeds BOTH forProvider and initProvider into that configuration, so
# either one puts the field back into every update. It must appear in neither.
# Nothing is lost by omitting it: the org setting is what applies signoff to a
# new repository, which is the same policy that makes the field unwritable here.
declared_signoff="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (
        (.spec.forProvider | has("webCommitSignoffRequired")) or
        (.spec.initProvider | has("webCommitSignoffRequired"))
      )
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$declared_signoff" ]] ||
  fail "org-controlled signoff must not be declared in forProvider or initProvider: $declared_signoff"

echo "repository-update-policy: OK — $active_count active repositories leave signoff to the org"
