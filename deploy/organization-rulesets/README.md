# `organization-rulesets/` — org rulesets as code

Declarative management of the devantler-tech org's **`OrganizationRuleset`** resources
(org-wide branch/tag protection and policies) as Crossplane managed resources, via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github)
(from the `integrations/github` Terraform provider). Repo-scoped `RepositoryRuleset`
resources live in the sibling [`../repository-rulesets/`](../repository-rulesets/).
Reconciled by the platform `github-config` tenant like the rest of `deploy/`.

## How adoption works

- **Observe-first (read-only).** Existing rulesets are bound with
  `managementPolicies: ["Observe"]` — Crossplane mirrors live GitHub state into
  `status.atProvider` and **never writes, reverts, or deletes**. This is pure GitOps
  *visibility*, with zero behaviour change (the same flow `repositories/` and `teams/`
  used). `Delete` is omitted everywhere, so a CR/Flux prune can never delete a real
  ruleset.
- **external-name = the import id.** `OrganizationRuleset` → the numeric ruleset id
  (`gh api orgs/devantler-tech/rulesets`); `RepositoryRuleset` → `<repo>:<id>`.
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
| 10 `OrganizationRuleset` files | the 10 org rulesets below | Observe (read-only import) |
| `protect-release-tags.yaml` | **Protect release tags** (net-new) | Managed (Create) — block tag delete + force-move + require `v<semver>` |
| `require-coderabbit-review.yaml` | **Require CodeRabbit review** (net-new) | Managed (Create) — require the `CodeRabbit` status check on the default branch of every repo |
| (in `../repository-rulesets/`) `require-merge-queue-on-platform.yaml` | `platform` "Require merge queue" | Observe (read-only import) |

The 10 imported org rulesets: Block force pushes · Require a pull request before
merging · Require conversation resolution before merging · Require linear history ·
Require signed commits · Require status checks to pass · Restrict deletions · Restrict
branch names · Restrict commit metadata · Require workflows (DependencyReview).

## What stays UI-managed, and why

`provider-upjet-github` v0.19.1 has a **narrower** ruleset schema than GitHub's API.
Verified against the live CRDs, it does **not** support:

- **`repository_property` conditions** (custom-property scoping) — only `refName`,
  `repositoryName`, `repositoryId`.
- **Rule types** `code_quality`, `copilot_code_review`, `repository_transfer`,
  `repository_name`, and the push-file rules (`file_path_restriction`, `max_file_size`,
  `file_extension_restriction`, `max_file_path_length`).
- **Target `repository`** (only `branch`, `tag`, `push`).
- **Bypass actor `EnterpriseOwner`**.

So **10 of the 20 org rulesets cannot be faithfully expressed** and remain UI-managed:

| Ruleset (org) | Blocked by |
|---|---|
| Require code scanning results | `repository_property` condition (custom property `Type`) |
| Require workflows … EnableAutoMerge | `repository_property` condition |
| Require workflows … LintDocumentation | `repository_property` condition |
| Require workflows … ScanGitHubActions | `repository_property` condition |
| Require workflows for .NET | `repository_property` condition (`language`) |
| Require workflows for Go | `repository_property` condition (`language`) |
| Require code quality results | rule type `code_quality` unsupported |
| Automatically request Copilot code review | rule type `copilot_code_review` unsupported (also disabled) |
| restrict-names | target `repository` unsupported |
| restrict-transfers | target `repository` unsupported (+ `EnterpriseOwner` bypass) |

These are tracked for re-adoption as the provider gains support in
[#69](https://github.com/devantler-tech/.github/issues/69) (`roadmap`). Re-home each
here Observe-first once expressible.

## Push / tag / Actions-policy considerations

- **Push rulesets** — none exist, and **not adoptable**: the provider supports
  `target: push` (beta) but none of the push-file rule types above, so a push ruleset
  can't be expressed. Tracked in [#69](https://github.com/devantler-tech/.github/issues/69).
- **Tag rulesets** — none existed; **added** here (`protect-release-tags.yaml`). Makes
  release tags immutable (block delete + force-move) and well-formed (`v<semver>`). See
  that file's header for the team-vs-enterprise tier caveat on the name-pattern rule and
  its fallback.
- **Actions policies** — the 2026-06-18
  [workflow execution protections](https://github.blog/changelog/2026-06-18-control-who-and-what-triggers-github-actions-workflows/)
  (actor + event allow-lists controlling who/what triggers workflows, delivered as org
  rulesets scoped by **custom properties**) are **not adoptable**: the new rule types
  aren't in the provider and the feature relies on the `repository_property` scoping the
  provider lacks. Tracked in [#69](https://github.com/devantler-tech/.github/issues/69);
  revisit when the provider catches up.
