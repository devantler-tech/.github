# `organization-rulesets/` — org rulesets as code

Declarative management of the devantler-tech org's **`OrganizationRuleset`** resources
(org-wide branch/tag protection and policies) as Crossplane managed resources, via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github)
(from the `integrations/github` Terraform provider). Repo-scoped `RepositoryRuleset`
resources live in the sibling [`../repository-rulesets/`](../repository-rulesets/).
Reconciled by the platform `github-config` tenant like the rest of `deploy/`.

## How adoption works

- **Observe-first (read-only).** The ten Observe-only org imports are bound with
  `managementPolicies: ["Observe"]` — Crossplane mirrors live GitHub state into
  `status.atProvider` and **never writes, reverts, or deletes**. This is pure GitOps
  *visibility*, with zero behaviour change (the same flow `repositories/` and `teams/`
  used). The [retained signing rule](#retained-signing-rule-record) and fully adopted
  [Go workflow rule](#organization-go-workflow-policy) use only Observe and Update.
  The signing rule preserves its disabled record; the Go rule uses the maintained catalogue. `Delete` is
  omitted everywhere, so a CR/Flux prune can never delete a real ruleset.
- **external-name = the numeric ruleset id**, for both Kinds — `OrganizationRuleset`
  (`gh api orgs/devantler-tech/rulesets`) and `RepositoryRuleset`
  (`gh api repos/devantler-tech/<repo>/rulesets`) alike. Terraform's
  `<repo>:<ruleset_id>` is the **import** id, not the stored external-name: the provider
  parses this annotation with `strconv.ParseInt`, so a `<repo>:`-prefixed value never
  observes. (The composite `<team_id>:<repository>` form in `../team-repositories/` is a
  different Kind and genuinely does take two parts — do not generalise it to rulesets.)
- **forProvider is identity-only** on the Observe imports (`name`/`target`/
  `enforcement`). ⚠️ **Do not** promote an import past `Observe` without first
  backfilling its full `rules`/`conditions`/`bypassActors` from the observed
  `status.atProvider` — the provider's round-trip is lossy, so a partial `forProvider`
  under `Update` would wipe live rules.

## What is managed here

**One `OrganizationRuleset` per file**, named after the rule it enforces (an active
verb — e.g. `require-pull-request.yaml`). Repo-scoped rulesets live next door in
[`../repository-rulesets/`](../repository-rulesets/) as `<verb>-on-<repo>.yaml`.

| Files | Rulesets | Policy |
|---|---|---|
| 10 `OrganizationRuleset` files | the imported org rulesets below except Require signed commits and Require workflows (Go) | Observe (read-only import) |
| `require-signed-commits.yaml` | **Require signed commits** (existing, retired) | Observe + Update — retain the disabled record; never create or delete |
| `require-workflows-go.yaml` | **Require workflows to pass before merging for Go** (existing, adopted) | Observe + Update — preserve the complete observed policy and require the maintained Go workflow; never create or delete |
| `protect-release-tags.yaml` | **Protect release tags** (net-new) | Managed (Create) — block tag delete + force-move + require `v<semver>` |
| `require-world-at-ruin-trusted-regressions.yaml` | **Require workflow - World at Ruin trusted regressions** (net-new) | Managed (Create) — target only World at Ruin and require the canonical catalogue's trusted regression workflow |
| `require-monorepo-ci-aggregate-contract.yaml` | **Require workflow - Monorepo CI aggregate contract** (net-new) | Managed (Create) — target only monorepo and require the aggregate-execution control from its reviewed `main` |
| `require-dotgithub-deploy-guards.yaml` | **Require workflow - .github deploy guards** (net-new) | Managed (Create) — target only this repository and run the `deploy/` release-contract and deletion validators from its reviewed `main` |
| `require-go-template-validation.yaml` | **Require workflow - Go template validation** (net-new) | Managed (Create) — target only go-template and require the canonical Go validation workflow from this repository's reviewed `main`, restoring the gate the property-conditioned UI ruleset stopped applying there |
| `require-dotnet-template-tests.yaml` | **Require workflow - .NET template tests** (net-new) | Managed (Create) — target only dotnet-template and require the canonical .NET tests workflow from this repository's reviewed `main`, supplying the build and test gate the UI ruleset does not apply there |
| `require-metadata-code-scanning-results.yaml` | **Require code scanning results - Metadata** (net-new) | Managed (Create) — centrally require CodeQL with both finding thresholds at all on `.github` and `monorepo`; no bypass actors |
| (in `../repository-rulesets/`) `require-merge-queue-on-platform.yaml` | `platform` "Require merge queue" | Observe + Update (managed import, full ruleset backfilled) |

The 12 imported org rulesets: Block force pushes · Require a pull request before
merging · Require conversation resolution before merging · Require code scanning results · Require linear history ·
Require signed commits · Require status checks to pass · Restrict deletions · Restrict
branch names · Restrict commit metadata · Require workflows (DependencyReview) · Require workflows (Go).

### Organization Go workflow policy

`require-workflows-go.yaml` adopts existing rule `10320335` after its complete
Observe-only readback. It retains active enforcement, the system `language: Go`
repository selector, default branches, the existing OrganizationAdmin bypass and
`doNotEnforceOnCreate`. Its required workflow now comes from this maintained
catalogue, repository `933213756`, at the same path and `refs/heads/main`.

The complete policy is backfilled before permitting Update; Create, Delete and
LateInitialize remain excluded. ID-less OrganizationAdmin actors omit `actorId`
as required by the provider schema. `tests/go-workflow-observation.sh` compares
the real rendered policy with an integrity-bound complete pre-migration snapshot,
allowing only that source replacement and the ID-less representation. It rejects
selector, bypass, workflow and authority drift, as well as duplicate adoption.

Native inherited-rule and qualifying consumer CI readback remain on
[#645](https://github.com/devantler-tech/.github/issues/645). Source adoption alone
does not prove a runtime improvement or sustained cache budget. The managed CodeQL
writer and remaining migration families stay separate under #237/#565.

### Organization CodeQL observation

`require-code-scanning-results.yaml` imports the existing organization rule
`6455804` with Observe only. Reconciliation exposed its complete repository-property
selector: Type is Application, Library, Marketplace or Infrastructure. Its default-branch
selector, CodeQL thresholds at `all` and existing OrganizationAdmin bypass are observed.
The import remains identity-only and read-only; it does not round-trip the policy.
`tests/code-scanning-ruleset.sh` preserves that boundary in required CI.

`.github` and `monorepo` have Type Metadata and successful default-branch CodeQL
analysis. The new `require-metadata-code-scanning-results.yaml` complements the
existing policy **at organization scope**, targeting just those stable repository IDs and
the default branch. Both finding thresholds are `all`, with no bypass actors and no
Delete permission. Stable repository IDs preserve coverage across renames without
adding a rename restriction. It does not enable a scanner, license or optional AI feature.
The whole Metadata category is not selected: category membership alone does not
prove applicable source and current analysis. New applicable repositories must be included in adoption-drift checks.

Issue #636 retains provider creation, native organization-rule and inherited-scope
readback, plus current-head positive and qualifying-finding refusal verification.
A merged manifest alone does not prove effective protection. The existing organization
Code Quality rule remains separate and is not round-tripped through this provider's
unsupported schema. No repository duplicate is introduced.

### Retained signing-rule record

`require-signed-commits.yaml` retains ruleset `5397812` with `enforcement: disabled`.
Its ref include list is empty, so it covers no branches. The complete observed
selectors, bypass list and rule fields are declared before allowing `Update`;
`Create`, `Delete` and `LateInitialize` remain excluded. The disabled record makes
the control's actual coverage clear without changing effective branch protection.

The effective pull-request, required-status-check and linear-history controls
remain separate. GitHub-created signed squash commits are outcome evidence, not
native signature enforcement. GitHub's
[signed-commit rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-signed-commits)
restrict squash merging another author's pull request when signatures are required.
Any future enforcement proposal must first prove the bot and contributor merge
paths are compatible; changing the empty ref selector is not part of this retirement.
The retirement decision and evidence are tracked in
[#132](https://github.com/devantler-tech/.github/issues/132).

## Provider capability and adoption gates

The reviewed [v0.20.0 OrganizationRuleset schema](https://github.com/crossplane-contrib/provider-upjet-github/blob/a211e095e2fe49c477836acec2ad4a28aa60e030/package/crds/enterprise.github.m.upbound.io_organizationrulesets.yaml)
has Git blob `566bb7e5736b64f4e60920e2f52e986c26a53ce4` and SHA-256
`f50cfddb37f198f32ed950172fbf1c7891ca70806b379aa325098e85c5dacfad`.
The same bytes appear at upstream main `0609e5fcca24d0f737c8cd9c6b4a39439f51f3ba`.
Schema support determines what can be declared; it does not prove adoption,
reconciliation or effective protection. Each adoption still needs Observe-first
inventory, a reviewed full resource and live readback.

| Capability | Reviewed schema | Remaining gate |
|---|---|---|
| Custom-property scoping | `conditions.repositoryProperty` is present | Full ruleset adoption and selector readback in [#69](https://github.com/devantler-tech/.github/issues/69) / [#121](https://github.com/devantler-tech/.github/issues/121) |
| Copilot review | `rules.copilotCodeReview` is present | Maintainer activation decision and adoption; support does not enable review |
| Push-file restrictions | All four restriction types and target `push` are present | A reviewed policy, scope and live positive/negative controls |
| Required status checks | `doNotEnforceOnCreate` is a typed Boolean | Runtime create/reconcile evidence; imported rules remain Observe-only |
| Enterprise-owner bypass | `EnterpriseOwner` is present | Declare the exact approved bypass list during adoption |
| Code-quality rule | `codeQuality` is absent | Provider support in #69 / #121 |
| Repository name and transfer rules | Target `repository` and `repositoryTransfer` are absent | Provider support; an available bypass actor does not supply the missing rule |
| Secret-scanning alert resolution | `require_secret_scanning_alert_resolution` and its parameters are absent | [#194](https://github.com/devantler-tech/.github/issues/194): provider support or an approved adapter, plus real merge-blocking controls |

The [release's complete CRD tree](https://github.com/crossplane-contrib/provider-upjet-github/tree/a211e095e2fe49c477836acec2ad4a28aa60e030/package/crds)
also contains organization and repository Actions
permissions with `shaPinningRequired`, and `RepositoryCollaboratorSet`. Those
#121 tasks are expressible, with authoritative ownership and live enforcement
readback still required. Organization settings and actor/event workflow execution
protection have no generated resource in that tree. Actions permissions and SHA
pinning cannot stand in for those distinct policies.

There is no current ruleset census in this schema inspection. Do not derive a
remaining-rule count from the earlier inventory or from an admin-team audit PASS.
Team assignment coverage, ruleset adoption and maintenance retirement are separate
gates; a team audit cannot clear the latter two.

## Push / tag / Actions-policy considerations

- **Push rulesets** — the reviewed schema can express their file restrictions.
  Adoption remains issue-driven in [#69](https://github.com/devantler-tech/.github/issues/69);
  schema support alone neither creates a policy nor proves its live coverage.
- **Tag rulesets** — none existed; **added** here (`protect-release-tags.yaml`). Makes
  release tags immutable (block delete + force-move) and well-formed (`v<semver>`). See
  that file's header for the team-vs-enterprise tier caveat on the name-pattern rule and
  its fallback.
- **Required-workflow source pins** — v0.20.0 exposes the source repository, path and a
  branch/tag `ref`, but not GitHub's immutable workflow `sha` selector. The World at Ruin
  rule therefore binds the external trusted source to `devantler-tech/.github` on
  `refs/heads/main`; Actions review and merge gates own source changes until the provider
  exposes `sha`.
- **Actions policies** — the 2026-06-18
  [workflow execution protections](https://github.blog/changelog/2026-06-18-control-who-and-what-triggers-github-actions-workflows/)
  (actor + event allow-lists controlling who/what triggers workflows, delivered as org
  rulesets scoped by **custom properties**) have no generated provider resource.
  Custom-property scoping is supported; the execution-policy resource remains the
  distinct gap. Tracked in [#69](https://github.com/devantler-tech/.github/issues/69);
  revisit when the provider catches up. Until then they are declared in
  [`workflow-execution-policies/`](../../workflow-execution-policies/) and applied by a workflow;
  moving them here is [#226](https://github.com/devantler-tech/.github/issues/226).
