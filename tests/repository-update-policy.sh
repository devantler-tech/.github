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

# Archived repositories are read-only in GitHub. Their one-time archive update
# has already landed, so retaining Update or LateInitialize would let a newly
# exposed/computed provider field create a permanent diff and retry an update
# GitHub cannot apply. Keep the steady state strictly Observe-only.
archived_repositories="$(
  yq -N '
    select(.kind == "Repository" and .spec.forProvider.archived == true) |
    .metadata.name
  ' "$render"
)"
archived_count="$(printf '%s\n' "$archived_repositories" | grep -c . || true)"
[[ "$archived_count" -ge 2 ]] ||
  fail "archived Repository set collapsed to $archived_count entries"

write_enabled_archived_repositories="$(
  yq -N '
    select(
      .kind == "Repository" and
      .spec.forProvider.archived == true and
      ((.spec.managementPolicies | sort | join(",")) != "Observe")
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$write_enabled_archived_repositories" ]] ||
  fail "archived Repository resources must be Observe-only after the archive update lands: $write_enabled_archived_repositories"

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

# ksail and platform host GitHub Pages sites built by workflows. They were
# adopted while LateInitialize copied the provider's deprecated `pages` field
# into desired state, including a `source` GitHub does not report for workflow
# builds (and, for platform, an empty cname). That permanent diff made every
# update call the Pages API, which the GitHub App deliberately cannot write
# (#232). Declaring `pages` exactly as GitHub reports it replaces the stale list
# as a whole (the CRD gives it no list type, so server-side apply treats it as
# atomic), so the provider sees no Pages change and never calls that API.
#
# The rollout is staged: both stay Observe-only until the live resources read back
# exactly the declared `pages`, and only then return to Observe/Create/Update.
declare_pages() {
  local name="$1" want_cname="$2" got
  got="$(
    yq -N -o=json -I=0 "
      select(.kind == \"Repository\" and .metadata.name == \"$name\") |
      {
        \"policies\": (.spec.managementPolicies | sort | join(\",\")),
        \"pages\": .spec.forProvider.pages
      }
    " "$render"
  )"
  [[ -n "$got" ]] || fail "$name Repository resource is missing"
  [[ "$(yq -N '.policies' <<<"$got")" == "Observe" ]] ||
    fail "$name must stay Observe-only until the live resource reads back the declared Pages state: $got"
  [[ "$(yq -N '.pages | length' <<<"$got")" == "1" ]] ||
    fail "$name must declare exactly one forProvider.pages entry: $got"
  [[ "$(yq -N '.pages[0].buildType' <<<"$got")" == "workflow" ]] ||
    fail "$name Pages must declare buildType: workflow, as GitHub reports it: $got"
  [[ "$(yq -N '.pages[0] | has("source")' <<<"$got")" == "false" ]] ||
    fail "$name Pages must not declare a source; GitHub reports none for a workflow build: $got"
  if [[ -n "$want_cname" ]]; then
    [[ "$(yq -N '.pages[0].cname' <<<"$got")" == "$want_cname" ]] ||
      fail "$name Pages must declare cname: $want_cname, as GitHub reports it: $got"
  else
    [[ "$(yq -N '.pages[0] | has("cname")' <<<"$got")" == "false" ]] ||
      fail "$name Pages must not declare a cname; GitHub reports none: $got"
  fi
}
declare_pages ksail ksail.devantler.tech
declare_pages platform ""

# LateInitialize copies live-only values into forProvider, and everything in
# forProvider is sent on update PATCHes, so LateInitialize is what turns a
# live-only value into part of future payloads. The hazard is that pairing, not
# LateInitialize itself: during Observe-first adoption a repository runs on
# Observe+LateInitialize to mirror live state, sends nothing, and is safe.
# Delete would let a prune destroy a real repository and is never allowed.
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
# versus true diff. The deployed provider v0.20.0 embeds
# terraform-provider-github v6.13.0, whose upstream #2077 fix omits the
# unchanged field when another Repository setting changes.
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

# These discovery topics were removed only because the previous provider could
# not update any other Repository field under organization-enforced signoff.
# v0.20.0 removes that compatibility boundary, so both declarations must stay
# present instead of silently returning to the old workaround.
missing_agent_topics="$(
  yq -N '
    select(
      .kind == "Repository" and
      (.metadata.name == "agent-plugins" or .metadata.name == "agent-skills") and
      ((.spec.forProvider.topics // []) | length == 0)
    ) |
    .metadata.name
  ' "$render"
)"
[[ -z "$missing_agent_topics" ]] ||
  fail "agent repository topics must remain declarative under provider v0.20.0: $missing_agent_topics"

# The template intentionally does not use GitHub Projects.
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
  fail "platform-tenant-template must pin forProvider.hasProjects: false"

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
[[ "$platform_tenant_management_policies" == "Create,Observe,Update" ]] ||
  fail "platform-tenant-template must restore Update under provider v0.20.0: $platform_tenant_management_policies"

echo "repository-update-policy: OK — $archived_count archived repositories are Observe-only; $active_count active repositories declare safe update policy"
