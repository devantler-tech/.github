# `repository-rulesets/` — repo-scoped rulesets as code

Declarative management of individual repositories' **`RepositoryRuleset`** resources as
Crossplane managed resources, via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github).
Org-wide `OrganizationRuleset` resources live in the sibling
[`../organization-rulesets/`](../organization-rulesets/), whose
[`README.md`](../organization-rulesets/README.md) documents the shared **Observe-first**
adoption convention and the provider importability matrix.

**One `RepositoryRuleset` per file**, named `<verb>-on-<repo>.yaml` so the rule and its
target repo are clear from the filename. external-name = the **bare numeric ruleset id**
(same as `../organization-rulesets/`; the provider stores `RepositoryRuleset.id`
from-provider). The Terraform `<repo>:<ruleset_id>` form is the *import* id only — using
it as the external-name fails the provider's `strconv.ParseInt` so the resource never
observes.

| File | Repo | Ruleset | Policy |
|---|---|---|---|
| `require-cla-gate-on-world-at-ruin.yaml` | `world-at-ruin` | Require CLA gate | Managed (net-new; Observe + Create + Update + LateInitialize) |
| `require-merge-queue-on-agent-plugins.yaml` | `agent-plugins` | Require merge queue | Managed (net-new; Observe + Create + Update + LateInitialize, no Delete); settings copied from platform |
| `require-merge-queue-on-platform.yaml` | `platform` | Require merge queue | Managed import (Observe + Update; full ruleset backfilled, no LateInitialize, no Delete) |
| `require-reviewed-admission-on-monorepo.yaml` | `monorepo` | Require reviewed repository admission | Managed, active; exact GitHub Actions executed result, default branch only, no bypass or Delete |
| `require-reviewed-admission-on-dotgithub.yaml` | `.github` | Require reviewed repository admission | Managed, active; exact GitHub Actions executed result, default branch only, no bypass or Delete |
| `require-reviewed-admission-on-world-at-ruin.yaml` | `world-at-ruin` | Require reviewed repository admission | Managed, active with the shared runner after native 187-scene positive and tampering-refusal proof; identity, selector and producer unchanged; the old singleton is retired |
| `require-scaffold-validation-on-platform-tenant-template.yaml` | `application-template` | Require scaffold validation | Managed (net-new; Observe + Create + Update + LateInitialize) |

The `go-template` and `dotnet-template` validation rules were withdrawn when both templates
retired and were archived (ADR 0018, devantler-tech/monorepo#5062). Their resources omit
`Delete`, so the withdrawal changed nothing on GitHub. A producer binding does not authenticate
the immutable workflow source.

The platform tenant template rule requires the three jobs of its `🧱 Validate Scaffold` workflow:
`Validate Scaffold`, `Platform Admissibility` and `Pod Security and tenant RBAC`. Every tenant
starts from that repository's `main`, so a scaffold that fails validation, or a publisher the
Platform has not approved, must not merge. The jobs run only in the template repository and skip
themselves in tenants, so the rule belongs to that repository and not to tenant CI.

Most files here are Observe-first imports of a ruleset created out of band, so they carry a
numeric `crossplane.io/external-name`. A **net-new** ruleset is the exception: it has no
external-name and is managed (never `Delete`), so Crossplane
creates it on first reconcile. Keep `LateInitialize` on a net-new ruleset: without it the
provider never writes the created id back as the external-name, so a provider restart would
create a second copy.
`../organization-rulesets/protect-release-tags.yaml` is the org-level precedent for that shape.

An **imported** ruleset promoted past Observe (today only `require-merge-queue-on-platform.yaml`)
takes `Observe` + `Update` and nothing else: no `Create`, because it already exists, and no
`Delete`, so removing the file orphans the ruleset instead of deleting a live gate. Without
`LateInitialize`, Update applies exactly what the file declares, so the file must carry the
**whole** observed ruleset — every rule, condition and bypass actor — or the next reconcile
removes what it left out. Leave `actorId` unset for an `OrganizationAdmin` bypass actor.
