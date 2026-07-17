# `deploy/` — declarative GitHub state

This directory is the source of truth for the devantler-tech org's GitHub
configuration, expressed as [Crossplane](https://crossplane.io) managed
resources (via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github)).

On every `v*` tag, [`cd.yaml`](../.github/workflows/cd.yaml) publishes this
directory as a **cosign-signed OCI artifact** to
`ghcr.io/devantler-tech/github-config/manifests`. The
[platform](https://github.com/devantler-tech/platform) cluster onboards it as
the **`github-config` tenant**: it verifies the signature, then Flux + Crossplane
reconcile the live GitHub org to match these manifests — including reverting
out-of-band changes made in the GitHub UI.

- `repositories/` — one `Repository` per managed repo.
- `archived-repositories/` — one `Repository` per archived (or archival-bound)
  repo, kept outside `repositories/` so its shared merge-policy patch never
  targets a read-only repo (each patched reconcile would 422). Observe-first,
  then a single `archived: true` flip; the two-phase lifecycle is documented in
  that dir's `kustomization.yaml`.
- `teams/` — one `Team` per file. `maintainers` is Observe-adopted; the
  separate `admins` policy actively manages explicit repository-admin grants.
- `team-memberships/` — one `TeamMembership` per file (`add-<user>-to-<team>.yaml`).
- `team-repositories/` — one `TeamRepository` per file (`grant-<team>-on-<repo>.yaml`),
  each granting a team a permission on a repo. The active policy grants
  `maintain` to Maintainers and `admin` to Admins without claiming Delete.
- `labels/` — one `IssueLabels` per managed repo. The canonical org label
  taxonomy lives once in `labels/kustomization.yaml` (a shared patch appended to
  every repo); each `<repo>.yaml` adds only that repo's Dependabot/Renovate
  ecosystem extras. Authoritative — out-of-band label drift is reverted. This is
  the Crossplane replacement for the old EndBug/label-sync workflow.
- `organization-rulesets/` — one `OrganizationRuleset` per file (org-wide branch/tag
  protection). 10 existing org rulesets are adopted **Observe-first** (read-only) + 1
  net-new `v*` tag-protection ruleset is managed. The 10 org rulesets the provider
  can't yet express stay UI-managed — see
  [`organization-rulesets/README.md`](organization-rulesets/README.md) for the full
  importability matrix and the push/tag/Actions-policy analysis.
- `repository-rulesets/` — one `RepositoryRuleset` per file (`<verb>-on-<repo>.yaml`),
  each a repo-scoped rule adopted Observe-first.
- `repository-permissions/` — one `RepositoryPermissions` per managed repo enforcing
  **Require actions to be pinned to a full-length commit SHA**
  (`sha_pinning_required`). The policy is asserted once via a shared patch in
  `repository-permissions/kustomization.yaml`; scope is **every repo in `labels/`**
  (`actions` included — its former exception was removed once its tag-pins were
  reverted). Live enforcement is still gated on a provider-upjet-github release
  embedding terraform-provider-github ≥ 6.11.0 (the field is absent in the deployed
  v0.19.1) and activation of `repositorypermissions.actions.github.m.upbound.io` in
  the platform MRAP.

## Roadmap

GitHub Issues are the roadmap of record. Epic
[#56](https://github.com/devantler-tech/.github/issues/56) tracks the current
GitHub-as-code programme in three phases:

1. **Foundation** — publish the signed artifact and Observe-adopt repositories,
   teams, and provider credentials without assuming delete ownership (landed).
2. **Coverage** — extend the declarative source of truth across labels,
   rulesets, team access, repository metadata, and remaining org settings
   through the epic's linked children (active).
3. **Enforcement** — move each supported object from observation to active
   reconciliation only after its live state matches the manifest; retain the
   no-`Delete` policy until deletion is explicitly designed and reviewed.

## Credentials & refresh behavior

The provider authenticates as a GitHub App whose credentials are **not** stored
here: [`external-secret.yaml`](external-secret.yaml) is an
[External Secrets](https://external-secrets.io) `ExternalSecret` that syncs them
from the platform cluster's OpenBao `SecretStore` into the `github-app-credentials`
Secret consumed by [`provider-config.yaml`](provider-config.yaml), re-reading the
source every `refreshInterval: 1h`. Two operational consequences:

- **A credential rotated in OpenBao propagates within the hour** — no manifest
  change or redeploy needed.
- **OpenBao being unreachable does not break reconciliation immediately**: the
  ExternalSecret's `Ready` condition goes `False` (typically with reason
  `SecretSyncedError`) but the last-synced Secret stays in place, so Crossplane
  keeps reconciling on cached credentials until a refresh succeeds (or the
  credentials themselves expire). A `Ready=False` refresh error alone is
  therefore a degraded-refresh signal, not an outage of the github-config tenant.

## Authoring changes

The authoring conventions live in the repo's [`AGENTS.md`](../AGENTS.md) (the
canonical instructions file, for humans and AI agents alike) — in short:
declarative-only (never `gh api` writes or UI changes to managed config),
**Observe-first** adoption of live objects (`crossplane.io/external-name` +
a management policy excluding `Delete`), team-based ownership, and
`IssueLabels` declared as a complete superset of a repo's live labels. Validate
before every PR with exactly what CI runs:

```sh
kubectl kustomize deploy/ > /dev/null
```

See the platform repo's
[`docs/github-management.md`](https://github.com/devantler-tech/platform/blob/main/docs/github-management.md)
for the architecture, the GitHub App credential setup, and the **Observe-first**
adoption flow for bringing an existing repository under management without any
risk of recreating or deleting it.

## Admins policy

Issue [#95](https://github.com/devantler-tech/.github/issues/95) and PR
[#96](https://github.com/devantler-tech/.github/pull/96) defined and validated
the separate `Admins` team, its explicit maintainer membership, and its
repository grants in both disabled and enabled states. Issue
[#102](https://github.com/devantler-tech/.github/issues/102) activates that
policy for the 21 active portfolio repositories, including `kyverno-policies`
and `world-at-ruin`. The archived `reusable-workflows` repository remains
excluded.

The active policy is fully declarative and omits both `Delete` management and
external names, so it cannot delete teams, memberships, or grants. Validate the
production render and policy invariants with:

```sh
kubectl kustomize deploy/ > /dev/null
bash tests/admin-team-policy.sh
```
