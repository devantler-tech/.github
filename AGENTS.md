# AGENTS.md — devantler-tech/.github (GitHub-as-code)

Conventions for AI agents and human contributors working in this repo. This is the **canonical**
instructions file (plain Markdown, read natively by GitHub Copilot — including **Copilot code
review** — Cursor, Codex, … and by Claude Code). It defers to the monorepo's root
[`AGENTS.md`](https://github.com/devantler-tech/monorepo/blob/main/AGENTS.md) for the **shared
engineering contract** (PR/commit conventions, trust gate, guardrails, draft-PR discipline); the
rules below are what's **specific to this repo**.

## What this repo is

Two unrelated things share one repo, by GitHub convention:

1. **The org's public profile** — `profile/README.md` (rendered on the org page), plus the org-wide
   community health files in [`.github/`](.github/) (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
   `SECURITY.md`, issue/PR templates) and the shared [`workflow-templates/`](workflow-templates/).
2. **The org's declarative GitHub configuration** — [`deploy/`](deploy/), the **source of truth for
   the devantler-tech org's GitHub state**, expressed as [Crossplane](https://crossplane.io) managed
   resources via
   [provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github).

On every `v*` tag, [`cd.yaml`](.github/workflows/cd.yaml) publishes `deploy/` as a **cosign-signed
OCI artifact** to `ghcr.io/devantler-tech/github-config/manifests`. The
[platform](https://github.com/devantler-tech/platform) cluster onboards it as the **`github-config`
tenant**, which verifies the signature and then has Flux + Crossplane **reconcile the live GitHub org
to match these manifests — including reverting out-of-band changes made in the GitHub UI or via
`gh api`**. See platform's
[`docs/github-management.md`](https://github.com/devantler-tech/platform/blob/main/docs/github-management.md)
for the architecture, the GitHub App credential setup, and the Observe-first adoption flow.

## Golden rules (repo-specific)

- **Manage GitHub declaratively — never imperatively.** Org / repo / team / label configuration is
  changed **only** by editing `deploy/` and shipping a PR. Do **not** use `gh api` writes or the
  GitHub UI to change managed config: the `github-config` tenant reverts out-of-band drift, so an
  imperative change is at best a no-op and at worst churns against the reconciler. (Reading via
  `gh api` is fine; *writing* managed config is not.) Applying an **existing** label to an issue is
  triage (content, allowed); creating or editing a label **definition** is config (declarative-only).
- **Ownership goes to a team, not an individual.** The canonical owner across the suite is the
  `maintainers` team — model access on `Team`/`TeamRepository`, never on individual logins.
- **Observe-first when adopting an existing resource.** A new `Repository`/`IssueLabels`/team CR for
  an already-live object must adopt it without risk of recreate/delete: set the
  `crossplane.io/external-name` annotation to the live name and use a management policy that
  **excludes `Delete`** (observe/late-initialize), per platform's `docs/github-management.md`. Once
  adopted, an active `Repository` runs on `Observe`/`Create`/`Update` **without `LateInitialize`**:
  the values late-initialized *during adoption* stay in `forProvider` as provider-owned state, and
  once `LateInitialize` is gone **no newly observed field is ever copied in again** — so a resource
  adopted without a given field never acquires it, and nothing but the config can supply it. A
  field the org already enforces, such as `webCommitSignoffRequired`, must be **declared in
  `forProvider` at the value the org enforces** — never left unconfigured and never seeded through
  the create-only `initProvider`. upjet builds the Terraform configuration from `forProvider`, an
  absent optional bool takes the provider's zero value of `false`, and `false` against a live `true`
  is a permanent diff, so every update PATCH carries `web_commit_signoff_required: false` and GitHub
  rejects the whole request with 422 "Commit signoff is enforced ... and cannot be disabled". The
  error names disabling, not presence: declaring the live value leaves nothing to diff, so Terraform
  omits the field from the payload and the update applies. `tests/repository-update-policy.sh` pins
  this. Verify
  the provider kind/field schema against the authoritative source
  ([crossplane-contrib/provider-upjet-github `package/crds/`](https://github.com/crossplane-contrib/provider-upjet-github)
  + `examples-generated/namespaced/`) — the CRs cannot be schema-validated locally (no cluster; CI
  only runs `kubectl kustomize`).
- **`IssueLabels` is authoritative** (Terraform `github_issue_labels`): it declares a repo's
  **complete** label set and **removes** any undeclared label. Before applying it to a repo with live
  labels, enumerate that repo's existing labels (including Dependabot's `dependencies` /
  `github_actions`, Renovate extras) so the declared set is a superset — or you will delete labels in
  use. The canonical taxonomy lives once in [`deploy/labels/kustomization.yaml`](deploy/labels/)
  (a shared patch appended to every repo); each `deploy/labels/<repo>.yaml` adds **only** that repo's
  automation-specific extras, including dependency/ecosystem labels and lifecycle labels that an
  automation requires to retain state.

## `deploy/` layout

| Path | Contents |
|---|---|
| `deploy/repositories/<repo>.yaml` | one `Repository` per managed repo (settings, merge/signoff, metadata) |
| `deploy/teams/` | one `Team` per file; includes the active Maintainers and Admins teams |
| `deploy/team-memberships/` | one explicit user-to-team membership per file |
| `deploy/team-repositories/` | one team-to-repository permission grant per file |
| `deploy/labels/<repo>.yaml` | one `IssueLabels` per repo; canonical taxonomy in `labels/kustomization.yaml` |
| `deploy/provider-config.yaml` | the provider-upjet-github `ProviderConfig` (App credentials) |
| `deploy/external-secret.yaml` | the `ExternalSecret` sourcing the GitHub App credentials |
| `deploy/kustomization.yaml` | top-level kustomization wiring the above + the shared repo-settings patch |

## Maintenance

The **roadmap of record** is GitHub Issues — epic [#56](https://github.com/devantler-tech/.github/issues/56)
("declarative GitHub-org-as-code") with `roadmap`-labelled children. Triage incoming issues into that
structure; implementing PRs use `Fixes #N`.

**Validate before every PR** (the sole required check, `CI - Required Checks`, gates on this):

```sh
kubectl kustomize deploy/ > /dev/null   # must build clean
bash tests/admin-team-policy.sh         # Admins policy invariants
bash tests/declarative-coverage.sh      # every repo declared in every rendered dimension
bash tests/declarative-coverage-fail-closed.sh # rendered-label reads fail closed
bash tests/repository-update-policy.sh  # active Repository update invariants
bash tests/release-contract.sh          # deploy/ changes must trigger a release
bash tests/repository-drift.sh          # declared-vs-live comparison logic
```

Those seven commands are the baseline checks that `ci.yaml` runs. Pull requests additionally pass
their changed paths and title through `scripts/validate-release-contract.sh`; merge groups skip that
event-specific check.

`kubectl` (with built-in kustomize) is preinstalled on CI runners. A clean build proves the manifests
are well-formed; the Crossplane CRDs themselves are applied/validated **on-cluster** (the
`github-config` tenant), not in CI — so a green build is necessary but not sufficient, and any new CR
must be schema-checked against the provider's published CRDs (above).

Repo-specific watch-list for the daily engineer:

- **Drift / coverage.** New repos in the org, or org/repo/team settings changed in the UI, mean
  `deploy/` is now behind reality. Bringing them under management (Observe-first) is `roadmap`/
  `enhancement` work — never a UI fix.
- **Declared settings that never landed.** `repository-drift-check.yaml` runs
  [`scripts/check-repository-drift.sh`](scripts/check-repository-drift.sh) and fails when a
  `forProvider` field disagrees with the live repository. Cluster state cannot answer this alone: a
  `Repository` only PATCHes when it has a pending diff, so an `Observe`-only resource — or one whose
  writes GitHub rejects — reports `Synced=ReconcileSuccess` while its declaration is never applied.
  A `DRIFT` line is a real defect in one of those two shapes; fix the resource, never the live repo.
  **It is `workflow_dispatch`-only** until the App holds `Administration: Read-only`
  ([#144](https://github.com/devantler-tech/.github/issues/144)) — GitHub returns the merge-policy
  and feature fields to no lesser scope, and requesting an ungranted permission fails the token step
  outright. Restore the daily `schedule:` with the permission.
- **`cd.yaml` is the publish path**, triggered on `v*` tags only; `ci.yaml` produces the PR-time
  required check. A red `cd.yaml` means the org-config OCI artifact didn't republish — investigate
  before assuming the live org is in sync.
- **Agent-file freshness.** Keep this `AGENTS.md` in sync with the actual `deploy/` layout and the
  shared contract. This repo does **not** carry a separate `.github/copilot-instructions.md` — Copilot
  reads `AGENTS.md` directly, so a parallel review-only file would be redundant (per the root contract,
  if one ever appears, delete it and fold anything unique here).
