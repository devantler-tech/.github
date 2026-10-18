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
| `require-codeql-findings-on-dotgithub.yaml` | `.github` | Require CodeQL findings | Managed (net-new; Observe + Create + Update + LateInitialize; never Delete) |
| `require-cla-gate-on-world-at-ruin.yaml` | `world-at-ruin` | Require CLA gate | Managed (net-new; Observe + Create + Update + LateInitialize) |
| `require-merge-queue-on-platform.yaml` | `platform` | Require merge queue | Managed import (Observe + Update; full ruleset backfilled, no LateInitialize, no Delete) |

Most files here are Observe-first imports of a ruleset created out of band, so they carry a
numeric `crossplane.io/external-name`. A **net-new** ruleset is the exception: it has no
external-name and is managed (never `Delete`), so Crossplane
creates it on first reconcile. Keep `LateInitialize` on a net-new ruleset: without it the
provider never writes the created id back as the external-name, so a provider restart would
create a second copy.
`../organization-rulesets/protect-release-tags.yaml` is the org-level precedent for that shape.

## Catalogue CodeQL protection

The separate catalogue rule requires `CodeQL`, blocks security findings rated high
or critical and other findings rated error, and targets only the default branch.
It declares no bypass actors. It reuses the existing CodeQL setup and analyses;
it neither enables another product/license nor adds a workflow or runner. The
existing native Code Quality rule retains its independent `all` threshold.

The [released provider schema](https://github.com/crossplane-contrib/provider-upjet-github/blob/a211e095e2fe49c477836acec2ad4a28aa60e030/package/crds/repo.github.m.upbound.io_repositoryrulesets.yaml)
and its namespaced example expose `requiredCodeScanning`. The nested field
descriptions do not enforce cardinality or threshold enums, so
`tests/code-scanning-ruleset.sh` checks the exact rendered policy and rejection
controls in the existing required manifest job. Do not round-trip the unsupported
Code Quality or secret-resolution fields through this resource.

GitHub's [native merge protection](https://docs.github.com/en/code-security/concepts/code-scanning/merge-protection)
judges findings intersecting the pull-request diff. It does not cover merge-queue
groups or Dependabot PRs analyzed by default setup. Existing dependency-review and
other required checks remain necessary; this rule cannot stand in for them or for
remediation of old default-branch findings. A configured tool is not successful
current analysis. Issue #636 retains reconciliation, effective default-branch
readback and native clean/refusal evidence until those are actually observed.

An **imported** ruleset promoted past Observe (today only `require-merge-queue-on-platform.yaml`)
takes `Observe` + `Update` and nothing else: no `Create`, because it already exists, and no
`Delete`, so removing the file orphans the ruleset instead of deleting a live gate. Without
`LateInitialize`, Update applies exactly what the file declares, so the file must carry the
**whole** observed ruleset — every rule, condition and bypass actor — or the next reconcile
removes what it left out. Leave `actorId` unset for an `OrganizationAdmin` bypass actor.
