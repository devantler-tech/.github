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
| `require-merge-queue-on-platform.yaml` | `platform` | Require merge queue | Observe (read-only import) |

Most files here are Observe-first imports of a ruleset created out of band, so they carry a
numeric `crossplane.io/external-name`. A **net-new** ruleset is the exception: it has no
external-name and is managed (never `Delete`), so Crossplane creates it on first reconcile.
`../organization-rulesets/protect-release-tags.yaml` is the org-level precedent for that shape.
