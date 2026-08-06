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

# Every active repository must declare webCommitSignoffRequired: true in
# forProvider, because the org enforces commit signoff and live is therefore
# always true. Leaving the field unconfigured does NOT keep it out of the update
# payload: upjet builds the Terraform configuration from forProvider, an absent
# optional bool takes the provider's zero value of false, and false against a
# live true is a permanent diff — so every update PATCH carries
# web_commit_signoff_required: false and GitHub rejects the whole request with
# 422 "Commit signoff is enforced by the organization and cannot be disabled".
# Declaring the live value leaves nothing to diff, so Terraform omits the field
# from the payload and the rest of the update applies.
#
# The 422 names disabling, not presence, and the cluster agrees: at
# 2026-07-27T04:34:5xZ, with this field declared by the shared patch, nine
# write-enabled repositories recorded LastAsyncOperation=Success — completed
# update PATCHes. Two minutes after the declaration was removed the same
# repositories began recording AsyncUpdateFailure carrying that 422, and seven
# were still failing on 2026-08-06. See devantler-tech/.github#112.
#
# initProvider is not a substitute: Crossplane applies it only at creation, so
# forProvider stays unconfigured and the permanent diff above is unchanged.
missing_signoff="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      .spec.forProvider.webCommitSignoffRequired != true
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$missing_signoff" ]] ||
  fail "active Repository resources must declare forProvider.webCommitSignoffRequired: true so updates carry no disabling value: $missing_signoff"

seeded_signoff="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (.spec.initProvider | has("webCommitSignoffRequired"))
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$seeded_signoff" ]] ||
  fail "signoff must be declared in forProvider, not the create-only initProvider: $seeded_signoff"

echo "repository-update-policy: OK — $active_count active repositories declare org-enforced signoff"
