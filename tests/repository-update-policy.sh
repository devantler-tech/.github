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
# forProvider because the org enforces commit signoff and live is therefore
# always true. Leaving the field unconfigured creates its own permanent false
# versus true diff. Declaring true removes that diff, but it does not make
# arbitrary updates safe with the deployed provider: v0.19.1 embeds
# terraform-provider-github v6.6.0, which still includes the unchanged field
# when another Repository setting changes, and GitHub rejects that PATCH.
# The compatibility guard below therefore also prevents the known optional
# topic drift until a provider release includes the upstream v6.12.0 fix.
#
# initProvider is not a substitute for the required live declaration:
# Crossplane applies it only at creation, so forProvider would remain false.
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

# This template's roadmap lives in its own GitHub Issues, so the active
# Repository resource must keep that tracker enabled. As with signoff above, an
# absent optional bool is not "unmanaged": provider zero-value behaviour makes
# false authoritative on every update. Requiring the exact true value rejects
# both removing the declaration and explicitly disabling it.
platform_tenant_issues="$(
  yq -N '
    select(
      .kind == "Repository" and
      .metadata.name == "platform-tenant-template"
    ) |
    .spec.forProvider.hasIssues |
    select(tag == "!!bool") |
    select(. == true)
  ' "$render"
)"
[[ "$platform_tenant_issues" == "true" ]] ||
  fail "platform-tenant-template must declare forProvider.hasIssues: true so its issue roadmap remains available"

# provider-upjet-github v0.19.1 embeds terraform-provider-github v6.6.0.
# GitHub rejects every repository PATCH containing web_commit_signoff_required
# while the organization enforces that setting, even when the requested value
# is true (integrations/terraform-provider-github#2077). Topic-only drift on
# these two resources therefore wedges the complete update. Keep the attempted
# topics absent until a provider-upjet-github release includes the upstream
# v6.12.0 fix, which omits the field when it is unchanged.
compatibility_repositories="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived != true and
      (.metadata.name == "agent-plugins" or .metadata.name == "agent-skills")
    ) |
    .metadata.name
  ' "$render" | sort
)"
expected_compatibility_repositories="$(printf '%s\n' agent-plugins agent-skills)"
[[ "$compatibility_repositories" == "$expected_compatibility_repositories" ]] ||
  fail "provider compatibility guard requires both agent repositories; got: $compatibility_repositories"

blocked_topic_updates="$(
  yq -N '
    select(
      .kind == "Repository" and
      (.metadata.name == "agent-plugins" or .metadata.name == "agent-skills") and
      (.spec.forProvider | has("topics"))
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$blocked_topic_updates" ]] ||
  fail "provider-upjet-github v0.19.1 cannot update repository topics under org-enforced signoff: $blocked_topic_updates"

# The template intentionally does not use GitHub Projects. Its resource also
# carries a failed asynchronous update from before the signoff workaround.
# Observe/Create keeps the existing repository healthy and recreatable without
# re-entering the provider's broken update path; restore Update with the same
# provider release that removes the compatibility boundary above.
platform_tenant_projects="$(
  yq -N '
    select(
      .kind == "Repository" and
      .metadata.name == "platform-tenant-template"
    ) |
    .spec.forProvider.hasProjects |
    select(tag == "!!bool") |
    select(. == false)
  ' "$render"
)"
[[ "$platform_tenant_projects" == "false" ]] ||
  fail "platform-tenant-template must pin forProvider.hasProjects: false while updates are compatibility-blocked"

platform_tenant_management_policies="$(
  yq -N '
    select(
      .kind == "Repository" and
      .metadata.name == "platform-tenant-template"
    ) |
    .spec.managementPolicies |
    sort |
    join(",")
  ' "$render"
)"
[[ "$platform_tenant_management_policies" == "Create,Observe" ]] ||
  fail "platform-tenant-template must remain Observe/Create without Update until the provider signoff fix is deployed: $platform_tenant_management_policies"

echo "repository-update-policy: OK — $active_count active repositories declare org-enforced signoff and the provider-v0.19.1 update workaround"
