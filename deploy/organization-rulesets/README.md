# `organization-rulesets/` — org rulesets as code

Declarative management of the devantler-tech org's **`OrganizationRuleset`** resources
(org-wide branch/tag protection and policies) as Crossplane managed resources, via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github)
(from the `integrations/github` Terraform provider). Repo-scoped `RepositoryRuleset`
resources live in the sibling [`../repository-rulesets/`](../repository-rulesets/).
Reconciled by the platform `github-config` tenant like the rest of `deploy/`.

## How adoption works

- **Observe-first (read-only).** The nine Observe-only org imports are bound with
  `managementPolicies: ["Observe"]` — Crossplane mirrors live GitHub state into
  `status.atProvider` and **never writes, reverts, or deletes**. This is pure GitOps
  *visibility*, with zero behaviour change (the same flow `repositories/` and `teams/`
  used). The [retained signing rule](#retained-signing-rule-record) and five fully adopted
  workflow rules use only Observe and Update.
  The signing rule preserves its disabled record; the workflow rules use the maintained catalogue. `Delete` is
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
| 9 `OrganizationRuleset` files | the imported org rulesets below except the six managed imports in this table | Observe (read-only import) |
| `require-signed-commits.yaml` | **Require signed commits** (existing, retired) | Observe + Update — retain the disabled record; never create or delete |
| `require-workflows-go.yaml` | **Require workflows to pass before merging for Go** (existing, adopted) | Observe + Update — preserve the complete observed policy and require the maintained Go workflow; never create or delete |
| 3 `require-workflows-*.yaml` imports | **DependencyReview**, **EnableAutoMerge** and **ScanGitHubActions** | Observe + Update — preserve the observed policy and maintained source; never create or delete |
| `require-workflows-dotnet.yaml` | language-selected **.NET** (retired) | Observe + Update — disabled with one inert rule (no required workflow; the provider requires a rules block) after a complete effective-policy census found no consumers; retain identity and selectors, never create or delete |
| `protect-release-tags.yaml` | **Protect release tags** (net-new) | Managed (Create) — block tag delete + force-move + require `v<semver>` |
| `require-world-at-ruin-trusted-regressions.yaml` | **Require workflow - World at Ruin trusted regressions** (retired) | Managed (Create), non-deleting — disabled with one inert rule and no workflow association after native shared-admission proof |
| `require-monorepo-ci-aggregate-contract.yaml` | **Require workflow - Monorepo CI aggregate contract** (retired) | Managed (Create), non-deleting — disabled with one inert rule and no workflow association after native shared-admission proof |
| `require-repository-pr-admission.yaml` | **Require workflow - Repository PR admission** | Managed (Create) — target monorepo, this catalogue and World at Ruin; trusted shared source runs each product-owned base-revision action, with a repository-bound executed result required for each |
| `require-dotgithub-deploy-guards.yaml` | **Require workflow - .github deploy guards** (retired) | Managed (Create), non-deleting — disabled with one inert rule and no workflow association after native shared-admission proof |
| `require-go-template-validation.yaml` | **Require workflow - Go template validation** (retired) | Managed (Create) — disabled after native repository validation proof; retain identity, selectors and non-deleting lifecycle |
| `require-dotnet-template-tests.yaml` | **Require workflow - .NET template tests** (retired) | Managed (Create) — disabled with one inert rule (no required workflow; the provider requires a rules block) after native repository validation proof; retain identity, selectors and non-deleting lifecycle |
| `require-metadata-code-scanning-results.yaml` | **Require code scanning results - Metadata** (net-new) | Managed (Create) — centrally require CodeQL with both finding thresholds at all on `.github` and `monorepo`; no bypass actors |
| (in `../repository-rulesets/`) `require-merge-queue-on-platform.yaml` | `platform` "Require merge queue" | Observe + Update (managed import, full ruleset backfilled) |

The 15 imported org rulesets: Block force pushes · Require a pull request before
merging · Require conversation resolution before merging · Require code scanning results · Require linear history ·
Require signed commits · Require status checks to pass · Restrict deletions · Restrict
branch names · Restrict commit metadata · Require workflows (DependencyReview) · Require workflows (Go) ·
Require workflows (EnableAutoMerge) · Require workflows (ScanGitHubActions) · Require workflows (.NET).

### Legacy required-workflow source migration

The four imported rules and two template-specific rules were observed completely
before this source migration. Their original default-branch selectors, repository
selectors, bypasses and creation behavior remain unchanged. Required workflows move
from the legacy catalogue to repository `933213756`, preserving each path and
`refs/heads/main`. The imports permit only Observe and Update; the two existing
managed template rules retain their previous lifecycle authority.

The complete pre-migration snapshots are integrity-bound in
`tests/fixtures/legacy-workflow-rulesets-observed.jsonl`. They are native policy
evidence, not repository-inherited API projections, which omit organization selectors.

Run `bash tests/legacy-workflow-observation.sh` from the repository root. It renders
the real configuration, compares every policy field with those observations and
allows the reviewed source switch, provider-required encodings, the proven
template cutovers and the narrowly scoped .NET retirement below. Its 113
rejection controls cover policy drift, excess authority, duplicate adoption,
incomplete input, additional legacy sources and weakened required CI invocation. Native readback and actual
ordinary consumer executions remain separate delivery gates under #237.

### Repository-owned template validation

The template-only organization policies are declared disabled after native overlap
proof: [Go control #422](https://github.com/devantler-tech/go-template/pull/422)
passed ordinary CI and then failed its required aggregate on an intentional test
failure; [.NET control #543](https://github.com/devantler-tech/dotnet-template/pull/543)
passed all three native platforms and then blocked on an intentional Windows
assertion failure (the unchanged fail-fast matrix cancelled its other two legs).
Neither control was merged.

`go-template-require-validation` requires the native `CI - Required Checks` aggregate.
`dotnet-template-require-validation` separately requires `.NET template tests`
for `ubuntu-latest`, `windows-latest` and `macos-latest`. Both remain active,
default-branch-only, without bypasses and bound to GitHub Actions integration `15368`.
The disabled organization resources retain their managed identities, complete selectors
and non-deleting lifecycle. The Go source remains genuinely shared. Both former .NET
policies now declare one inert rule each, removing obsolete workflow associations before wrapper
retirement. The language-selected policy has no consumer in a complete fresh effective-policy
census, and the template's replacement remains independently required. Native readback must
confirm both inert, disabled policies before source removal; this follow-through is tracked
in [#703](https://github.com/devantler-tech/.github/issues/703).

### Shared admission rollout

The shared runner enrolls monorepo, this configuration catalogue and World at Ruin. All three repositories also require
`Run reviewed product admission` from GitHub Actions. The source-only `Admission not selected`
result does not satisfy that requirement. Product validators and budgets come from their immutable
reviewed bases, never from candidate actions. All three former singleton organization associations
are disabled inert records, without workflow associations or deletion authority. Their identity
and narrow target selectors remain declared; the common workflow and all three repository result
bindings stay active without bypasses.

World's event and engine repairs ([#1550](https://github.com/devantler-tech/world-at-ruin/pull/1550),
[#1552](https://github.com/devantler-tech/world-at-ruin/pull/1552)) passed full CI and review and merged.
[Restoration #757](https://github.com/devantler-tech/.github/pull/757) was signed, published and
independently verified in the live reconciler and native policies before fresh controls:
the [opened event](https://github.com/devantler-tech/world-at-ruin/actions/runs/40199676030) and
[synchronized event](https://github.com/devantler-tech/world-at-ruin/actions/runs/40199849830)
each passed all 187 trusted scenes. The [deliberately tampered candidate](https://github.com/devantler-tech/world-at-ruin/actions/runs/40203805764)
was refused by the reviewed action during contained import, after immutable identity and engine setup
succeeded; its no-op candidate action could not supply a green result. The established gate remained
active throughout that overlap. Its retired record now preserves the original selector, identity and
non-deleting lifecycle without a workflow association. Read back this retirement's signed publication,
live application and native policies, then repeat positive and refusal controls with the old gate
inactive before claiming the cutover complete. Enrollment alone does not prove execution or protection.

Read back released native enforcement before exercising a product's real positive and tampering
controls. Those controls must pass for that product before its old association is retired. Per-product
acceptance and source cutovers are tracked in [#693](https://github.com/devantler-tech/.github/issues/693).
If a reviewed source blocks its own repair, use the maintainer-owned recovery procedure in
[Maintenance](../../AGENTS.md#maintenance), never candidate code or an automatic protection bypass.

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
| Custom-property scoping | `conditions.repositoryProperty` is present | Existing workflow-rule observation and adoption are recorded in [#674](https://github.com/devantler-tech/.github/issues/674); new rules still require their own selector readback |
| Copilot review | `rules.copilotCodeReview` is present | Not adopted: the maintainer's standing direction excludes Copilot review requests |
| Push-file restrictions | All four restriction types and target `push` are present | Not adopted for public repositories; an eligible private/internal policy needs a separate scoped decision |
| Required status checks | `doNotEnforceOnCreate` is a typed Boolean | Runtime create/reconcile evidence remains necessary; retain each resource's documented management policy |
| Enterprise-owner bypass | `EnterpriseOwner` is present | Declare the exact approved bypass list during adoption |
| Code-quality rule | `codeQuality` is absent | Provider support remains in [#69](https://github.com/devantler-tech/.github/issues/69) |
| Repository name and transfer rules | Target `repository` and `repositoryTransfer` are absent | Provider support; an available bypass actor does not supply the missing rule |
| Secret-scanning alert resolution | `require_secret_scanning_alert_resolution` and its parameters are absent | [#194](https://github.com/devantler-tech/.github/issues/194): provider support or an approved adapter, plus real merge-blocking controls |

The [release's complete CRD tree](https://github.com/crossplane-contrib/provider-upjet-github/tree/a211e095e2fe49c477836acec2ad4a28aa60e030/package/crds)
also contains organization and repository Actions
permissions with `shaPinningRequired`, and `RepositoryCollaboratorSet`. Schema
availability does not require adopting every resource. The decisions and completed
rollout are recorded in [#121](https://github.com/devantler-tech/.github/issues/121).

### Adoption decisions — 2026-10-28

- **Actions SHA pinning is delivered.** Per-repository `RepositoryPermissions`
  resources remain the authoritative owner. The complete dated organization
  readback covers 26 active repositories: all declare SHA pinning, report Ready
  and Synced, and independently return `sha_pinning_required: true` through
  GitHub's API. This is a dated acceptance snapshot; routine coverage and drift
  audits remain responsible for later changes.
- **Copilot review stays unadopted.** An automatic review ruleset would conflict
  with the maintainer's standing instruction against requesting Copilot reviews.
  This decision does not change unrelated Copilot features.
- **Push rulesets are not a public-repository control.** GitHub restricts their
  applicability to [private/internal repositories and their fork networks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets#push-rulesets).
  There is no approved private-repository restriction policy to implement here.
  Reconsider only for a concrete eligible scope, with its own reviewed policy and
  native positive/refusal controls. This is not a claim that eligible private
  repositories lack plan support.
- **Keep the existing collaborator owners.** `RepositoryCollaboratorSet` supports
  teams as well as users, but its wrapped Terraform resource is authoritative and
  [conflicts with `github_team_repository`](https://github.com/integrations/terraform-provider-github/blob/v6.13.0/docs/resources/repository_collaborators.md).
  This deployment already manages grants through `TeamRepository`; introducing a
  second authority would create competing reconcilers. No such adoption is
  planned. A future replacement would need a complete, separately reviewed
  ownership migration.
- **Organization settings remain owned by [#85](https://github.com/devantler-tech/.github/issues/85).**
  Follow the [maintainer's upstream-support direction](https://github.com/devantler-tech/.github/issues/85#issuecomment-4919334722),
  retaining the existing read-only observer. The released provider has no general
  organization-settings resource. The upstream path is provider generation for
  Terraform's [supported settings](https://github.com/integrations/terraform-provider-github/blob/v6.13.0/docs/resources/organization_settings.md),
  plus separate Terraform support for the absent `two_factor_requirement_enabled`
  setting. No custom write adapter is introduced; #85's implementation and live
  enforcement remain unfinished. External contributions require their separate
  authorization.

Actor/event workflow execution protection also has no generated resource in that
release tree. Actions permissions and SHA pinning cannot stand in for those distinct
policies. These non-adoption decisions install no additional protection or bypass.

There is no current ruleset census in this schema inspection. Do not derive a
remaining-rule count from the earlier inventory or from an admin-team audit PASS.
Team assignment coverage, ruleset adoption and maintenance retirement are separate
gates; a team audit cannot clear the latter two.

## Push / tag / Actions-policy considerations

- **Push rulesets** — retain the non-adoption decision above. Any future eligible
  private/internal proposal remains issue-driven in [#69](https://github.com/devantler-tech/.github/issues/69);
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
