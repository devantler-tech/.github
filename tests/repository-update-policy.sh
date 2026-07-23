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

active_repositories="$(
  yq -N '
    select(.kind == "Repository" and .spec.forProvider.archived != true) |
    .metadata.name
  ' "$render"
)"
active_count="$(printf '%s\n' "$active_repositories" | grep -c . || true)"
[[ "$active_count" -ge 10 ]] ||
  fail "active Repository set collapsed to $active_count entries"

late_initialized="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (.spec.managementPolicies | contains(["LateInitialize"]))
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$late_initialized" ]] ||
  fail "active Repository resources still allow LateInitialize: $late_initialized"

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
