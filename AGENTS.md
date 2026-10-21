# AGENTS.md — devantler-tech/.github (GitHub-as-code)

Conventions for AI agents and human contributors working in this repo. This is the **canonical**
instructions file (plain Markdown, read natively by GitHub Copilot — including **Copilot code
review** — Cursor, Codex, … and by Claude Code). It defers to the monorepo's root
[`AGENTS.md`](https://github.com/devantler-tech/monorepo/blob/main/AGENTS.md) for the **shared
engineering contract** (PR/commit conventions, trust gate, guardrails, draft-PR discipline); the
rules below are what's **specific to this repo**.

## What this repo is

Three things share one repo:

1. **The org's public profile** — `profile/README.md` (rendered on the org page), plus the org-wide
   community health files in [`.github/`](.github/) (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
   `SECURITY.md`, issue/PR templates) and the shared [`workflow-templates/`](workflow-templates/).
2. **The org's declarative GitHub configuration** — [`deploy/`](deploy/), the **source of truth for
   the devantler-tech org's GitHub state**, expressed as [Crossplane](https://crossplane.io) managed
   resources via
   [provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github).
3. **The suite's shared CI/CD building blocks** — composite actions and reusable workflows every
   product repository calls. See [Actions catalogue](#actions-catalogue).

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
  The one setting the provider cannot express yet, Actions workflow execution policies, is declared
  in [`workflow-execution-policies/`](workflow-execution-policies/) and applied from `main` by
  `apply-workflow-execution-policies.yaml`; change those by editing the files, never the live policy.
- **Ownership goes to a team, not an individual.** The canonical owner across the suite is the
  `maintainers` team — model access on `Team`/`TeamRepository`, never on individual logins.
- **Observe-first when adopting an existing resource.** A new `Repository`/`IssueLabels`/team CR for
  an already-live object must adopt it without risk of recreate/delete: set the
  `crossplane.io/external-name` annotation to the live name and use a management policy that
  **excludes `Delete`** (observe/late-initialize), per platform's `docs/github-management.md`. Once
  adopted, an active `Repository` normally runs on `Observe`/`Create`/`Update` **without `LateInitialize`**:
  the values late-initialized *during adoption* stay in `forProvider` as provider-owned state, and
  once `LateInitialize` is gone **no newly observed field is ever copied in again** — so a resource
  adopted without a given field never acquires it, and nothing but the config can supply it. A
  field the org already enforces, such as `webCommitSignoffRequired`, must be **declared in
  `forProvider` at the value the org enforces** — never left unconfigured and never seeded through
  the create-only `initProvider`. upjet builds the Terraform configuration from `forProvider`, an
  absent optional bool takes the provider's zero value of `false`, and `false` against a live `true`
  is a permanent diff, so every update PATCH carries `web_commit_signoff_required: false` and GitHub
  rejects the whole request with 422 "Commit signoff is enforced ... and cannot be disabled".
  Declaring the live value removes that field's own diff. The deployed provider-upjet-github
  v0.20.0 embeds terraform-provider-github v6.13.0, whose fix for
  [upstream #2077](https://github.com/integrations/terraform-provider-github/issues/2077) omits the
  unchanged field when another setting needs an update. Active repositories can therefore use
  `Update` while keeping the enforced live value explicit. The adopted private `client-orders`
  repository uses only `Observe`/`Update`: recreation is forbidden, privacy and Issues are explicit,
  and init-only public-safe seeds preserve its externally owned description, homepage and security
  settings. Never add those fields to `forProvider`, enable `Create` or `LateInitialize`, or copy
  private metadata into this repository. The `platform` and `ksail` Repository
  resources host workflow-built Pages sites that the GitHub App cannot write, so each declares the
  deprecated `pages` field exactly as GitHub reports it. Declaring the whole list replaces stale
  provider state and leaves no Pages diff for an update to send (issue #232). KHoist's newly
  bootstrapped site has no observed Pages block, so an enforced declaration instead retries a
  forbidden Pages PUT. Keep only its Pages bootstrap expectation in `initProvider.pages`, retain
  the homepage and repository settings in `forProvider`, and verify the Pages expectation through
  the read-only repository drift check (#614). Do not expand the managed App's Pages permissions.
  After a repository's one-time
  `archived: true` update lands, move it to exactly `Observe`: GitHub makes archived repositories
  read-only, and retaining `Update` or `LateInitialize` lets newly exposed provider fields create a
  permanent update loop. `tests/repository-update-policy.sh` pins both invariants. Verify
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
| `deploy/repository-permissions/<repo>.yaml` | one `RepositoryPermissions` per active (non-archived) repo; requires actions pinned to a full commit SHA |
| `deploy/provider-config.yaml` | the provider-upjet-github `ProviderConfig` (App credentials) |
| `deploy/external-secret.yaml` | the `ExternalSecret` sourcing the GitHub App credentials |
| `deploy/kustomization.yaml` | top-level kustomization wiring the above + the shared repo-settings patch |

## Maintenance

The **roadmap of record** is GitHub Issues — epic [#56](https://github.com/devantler-tech/.github/issues/56)
("declarative GitHub-org-as-code") with `roadmap`-labelled children. Triage incoming issues into that
structure; implementing PRs use `Fixes #N`.

Organization settings not represented by the provider are audited against
[`organization-settings/expected.json`](organization-settings/README.md). The check is read-only:
0 means all declared settings match, 1 means measured drift, and 2 means invalid or incomplete
evidence. Its manual workflow runs only on reviewed main after explicit opt-in, requests read
authority and never changes settings. Keep both observation/failure controls and the workflow
credential-boundary mutations in CI. Provider adoption remains in #85; scheduling and flag
retirement remain in #404.

Routine repository/admin-team monitoring is described in
[`.github/governance-audits.md`](.github/governance-audits.md). Its daily schedule is enabled;
manual execution is input-free and requires reviewed main. Keep admission, private-diagnostic suppression,
complete-outcome reporting and source/credential mutations in required CI. Routine admission has no experimental switches. Natural scheduled observation and
main dispatch prove both full checks and the reporter. Legacy maintenance retirement
remains a separate gate (#84).

The existing organization CodeQL finding rule is imported Observe-only. Run
`bash tests/code-scanning-ruleset.sh` after changing its identity, read-only
lifecycle or CI integration. Full observed selectors, thresholds and bypasses
are required before any managed adoption; see
[`deploy/organization-rulesets/README.md`](deploy/organization-rulesets/README.md)
and the remaining observation and coverage gates in #636. Run
`bash tests/metadata-code-scanning-ruleset.sh` after changing the separate
organization rule for `.github` and `monorepo`; preserve its exact verified scope,
all finding thresholds, no bypasses and non-deleting lifecycle. Native creation
and positive/refusal evidence remain separate delivery gates.

The adopted dependency-review, auto-merge, workflow-scanning and language-selected
.NET rules permit only Observe and Update after complete native observation (#674).
Run `bash tests/legacy-workflow-observation.sh` after changing these or the two
template workflow rules: it binds all six complete policies to their captured
native state, permitting only the maintained source, required provider encodings,
and disabled enforcement for the two template-only rules after native repository
validation proof (#698). Keep both replacement repository rules active, default-branch-only,
without bypasses and bound to their exact GitHub Actions checks. The Go aggregate and all
three distinct .NET platform checks were proven with positive and intentional-failure controls.
Native application and ordinary consumer execution remain separate gates under #237.

**Validate before every PR** (the sole required check, `CI - Required Checks`, gates on this):

```sh
kubectl kustomize deploy/ > /dev/null   # must build clean
bash tests/admin-team-policy.sh         # Admins policy invariants
bash tests/declarative-coverage.sh      # every repo declared in every rendered dimension
bash tests/declarative-coverage-fail-closed.sh # rendered-label reads fail closed
bash tests/repository-update-policy.sh  # active Repository update invariants
bash tests/signing-rule-retirement.sh  # retained signing-rule identity and safe lifecycle
bash tests/release-contract.sh          # deploy/ changes must trigger a release
bash tests/deploy-deletions.sh          # removed deploy/ resources must be acknowledged per resource
bash tests/repository-drift.sh          # declared-vs-live comparison logic
bash tests/repository-coverage.sh       # live-org-vs-deploy/ comparison logic
bash tests/workflow-execution-inventory.sh # who and what can start each workflow
bash tests/workflow-execution-actors.sh  # live actor IDs/types observed per workflow and event
bash tests/workflow-execution-policies.sh # reviewed execution policies are valid desired state
bash tests/apply-workflow-execution-policies.sh # the policy reconciler, against an offline API stand-in
```

Those fourteen commands are the baseline checks that `ci.yaml`'s `validate-manifests` job runs; the
same workflow also runs the catalogue's tests (see [Actions catalogue](#actions-catalogue)). Pull requests additionally pass
their changed paths and title through `scripts/validate-release-contract.sh` and their base/head
renders plus the pull-request body through `scripts/validate-deploy-deletions.sh` (every managed
resource that leaves the render needs its own `Deletion-Acknowledged: <Kind>.<group>/<name>` body line, spelled the way the
failure prints it); merge groups skip those event-specific checks. The deletion check also renders
`deploy/` at the base, so a pull request whose base `main` does not build fails there with kubectl's
exit status.

Both validators also run in `.github/workflows/deploy-guards.yaml`, which the
`require-dotgithub-deploy-guards` organization ruleset requires from reviewed `main`. That copy
checks the validators out at `github.workflow_sha` and reads the pull request only as data, so
editing `ci.yaml`, the workflow, or a validator in a pull request does not change the check that
judges it; such edits take effect only after they merge. Keep `tests/deploy-guards-ruleset.sh`
passing when either file changes. Because the repairing pull request cannot edit that check, a
`main` whose `deploy/` no longer renders needs an organization owner to set the ruleset's
enforcement to `evaluate` while the `github-config` reconciliation is suspended, then restore both.

Organization-required workflows ignore pull request title/body edits even when their trigger lists
`edited`. `pr-metadata-guards.yaml` provides manually dispatched read-only feedback from reviewed main.
It reads the current open catalogue PR through GitHub's API, binds validators to the workflow's
immutable source revision, and treats the candidate as data only. It refuses fork PRs and other
bases. It has no required-status binding; the existing full CI protection still applies.
Keep `.github/tests/test-ci-metadata-events.sh` passing. Retain catalogue CI's `edited` trigger
until trusted producer, current-head attribution and live enforcement are proven under #250.

`kubectl` (with built-in kustomize) is preinstalled on CI runners. A clean build proves the manifests
are well-formed; the Crossplane CRDs themselves are applied/validated **on-cluster** (the
`github-config` tenant), not in CI — so a green build is necessary but not sufficient, and any new CR
must be schema-checked against the provider's published CRDs (above).

Repo-specific watch-list for the daily engineer:

- **Drift / coverage.** New repos in the org, or org/repo/team settings changed in the UI, mean
  `deploy/` is now behind reality. Bringing them under management (Observe-first) is `roadmap`/
  `enhancement` work — never a UI fix. `repository-coverage-check.yaml` runs
  [`scripts/check-repository-coverage.sh`](scripts/check-repository-coverage.sh) daily at 05:29 UTC
  and on `workflow_dispatch`, and fails on an `UNDECLARED` live, non-archived repository. Its App
  token reads metadata across every installed repository, because scoping it to the declared ones
  would hide an undeclared private repository; it fails closed when the App installation is
  limited to selected repositories or the listing misses a declared one. A failing run on `main` opens the issue *Scheduled repository coverage check is failing on
  main*, and the next passing run closes it.
- **Declared settings that never landed.** `repository-drift-check.yaml` runs
  [`scripts/check-repository-drift.sh`](scripts/check-repository-drift.sh) and fails when a
  `forProvider` field disagrees with the live repository. Cluster state cannot answer this alone: a
  `Repository` only PATCHes when it has a pending diff, so an `Observe`-only resource — or one whose
  writes GitHub rejects — reports `Synced=ReconcileSuccess` while its declaration is never applied.
  A `DRIFT` line is a real defect in one of those two shapes; fix the resource, never the live repo.
  It runs daily at 05:17 UTC and on `workflow_dispatch`. The scoped App token reads repository
  settings through REST and fills missing merge-policy fields through GraphQL. Both reads must
  identify the same repository and visibility; missing fields or partial responses fail the check.
  A failing scheduled or dispatched run on `main` opens or updates the issue *Scheduled repository
  drift check is failing on main*, and the next passing run closes it; triage that issue like any
  other breakage. Runs are queued rather than overlapping, so an older result never overwrites a
  newer one. `tests/repository-drift.sh` pins that wiring.
- **Workflow execution policies are applied by a workflow, not Crossplane.**
  `apply-workflow-execution-policies.yaml` runs when a change to `workflow-execution-policies/` or
  its reconciler lands on `main`, daily at 05:43 UTC, and on `workflow_dispatch`. It mints a token
  from `APP_CLIENT_ID` / `APP_PRIVATE_KEY` with organization administration only, makes the live
  policies match the files by name, reads each back, and never deletes one. A red run names the
  policy and prints `FAILED`, `MISMATCH` or `UNKNOWN`; fix the file or the credential, never the
  live policy. Moving these into `deploy/` once the provider supports them is
  [#226](https://github.com/devantler-tech/.github/issues/226).
- **`cd.yaml` is the publish path**, triggered on `v*` tags only; `ci.yaml` produces the PR-time
  required check. A red `cd.yaml` means the org-config OCI artifact didn't republish — investigate
  before assuming the live org is in sync.
- **Agent-file freshness.** Keep this `AGENTS.md` in sync with the actual `deploy/` layout and the
  shared contract. This repo does **not** carry a separate `.github/copilot-instructions.md` — Copilot
  reads `AGENTS.md` directly, so a parallel review-only file would be redundant (per the root contract,
  if one ever appears, delete it and fold anything unique here).

## Actions catalogue

The shared actions and reusable workflows are governed by this core and the topic guides below.
Read each guide before doing the work its row names.

| Guide | Read before |
|---|---|
| [Catalogue layout and references](.github/agent-guides/catalogue.md) | Adding or moving components, self-references, release conventions |
| [Workflow and CI contracts](.github/agent-guides/workflows.md) | Any catalogue implementation, test or workflow change, including feature flags |
| [Validation and publication contracts](.github/agent-guides/validation.md) | Any catalogue validation, to-do forwarding, publication or release-recovery change |
| [Tested invariants](.github/agent-guides/invariants.md) | Any catalogue implementation or test change |

### Layout

The [catalogue layout](.github/agent-guides/catalogue.md#layout) lists component directories and all repository-owned workflows. Catalogue workflows declare `workflow_call`; the others operate this repository.

### Key configuration files

| File | Purpose |
|---|---|
| `.releaserc` | This repository's semantic-release configuration. The `create-release` self-test dry-run reads it too. |
| `.mega-linter.yml` | MegaLinter config (disables SPELL_CSPELL) |
| `.yamllint.yml` | YAML linting rules |
| `.cspell.json` | Spell-checker config and custom words |
| `.markdownlint.json` | Markdown linting rules |
| `zizmor.yml` | Zizmor security scanner pinning policies |

### Conventions

Full detail in [actions/CONTRIBUTING.md](actions/CONTRIBUTING.md). Key rules:

- **Action directory naming:** `actions/<active-verb>-<purpose>` (e.g., `setup-go-toolchain`, not `go-setup`)
- **Inputs/outputs:** kebab-case only (e.g., `app-id`, `github-token`)
- **Action type:** Prefer **composite** over JavaScript/Docker
- **External action pinning:** Pin third-party actions (non-`actions/*`, non-`github/*`, non-`devantler-tech/*`) to commit SHAs with a `# v<version>` comment — enforced by `zizmor.yml`. For a main-tracked dep with no releases, use `# <branch> (no upstream releases)`.
- **`action.yaml`:** Always set `author: devantler-tech`
- **Distribution / Marketplace:** Keep this portfolio-first catalogue directly reusable but intentionally unlisted in GitHub Marketplace while it contains multiple subdirectory actions and reusable workflows. Marketplace does not automatically list nested action metadata, so do not add `branding:` blocks as a proxy for publication.

#### Test jobs

Read the [workflow and CI contracts](.github/agent-guides/workflows.md#test-jobs) before adding or changing a test. Keep the required reducer, credential boundaries and native behavior proofs intact.

**Failure-mode coverage for gating workflows (the convention):** every **gating** reusable workflow — one whose job is to *fail a PR on bad input* — carries **both** a *passes-on-good-input* and a *blocks-on-bad-input* self-test, because a happy-path test alone cannot catch a gate that silently stopped biting. The pattern (per `test-govulncheck-strict-blocks` and `test-zizmor-blocks`): point the gate's **own** action — pinned to the **same SHA**, guarded by a `*-action-lockstep` check — at a deliberately-bad fixture under `.github/tests/`, `continue-on-error`, then assert the run *failed* **and** reported the expected finding (so an operational error can't false-pass). The fixture lives **outside** the gate's own scan scope (e.g. `.github/tests/zizmor-fixture/` is outside `.github/workflows/`) so it never trips the real gate. **Non-gating** workflows (release/publish/deploy dry-runs, `delete-workflow-runs`, `enable-auto-merge`, `template-sync`, `sync-cluster-policies`, `update-agent-skills`, `scan-for-todo-comments`) have no "bad input" to reject, so a happy-path `[Test]` job is complete coverage. Where a clean failure-mode fixture is genuinely impractical, record the reasoned gap rather than forcing a fragile test: the `dependency-review` workflow needs a PR diff introducing a bad dependency, so its blocking path is replayed at the action level by the offline `on-failure-vulnerable` scenario (see *Dependency-review comment coverage*) rather than through the workflow.

### Authentication Patterns

GitHub App tokens (not `GITHUB_TOKEN`) are used for operations that must trigger other workflows or bypass branch protection:

```yaml
- name: 🔑 Generate GitHub App Token
  uses: actions/create-github-app-token@<sha> # <version>
  id: app-token
  with:
    client-id: ${{ vars.APP_CLIENT_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
```

Two App identities exist:

- **botantler-1** — `APP_CLIENT_ID` (var) + `APP_PRIVATE_KEY` (secret): the primary release and automation identity (cuts releases, commits signed fixes, arms auto-merge).
- **botantler-2** — `APP_CLIENT_ID_2` (var) + `APP_PRIVATE_KEY_2` (secret): the approver identity for workflows that approve a pull request another identity opened (a pull request cannot be approved by its opener).

### Validation Commands

```bash
# Run yamllint
yamllint .github/workflows/

# Check action/workflow pinning with zizmor
zizmor --config zizmor.yml .github/workflows/

# Lint workflows (if installed)
actionlint
```

### Maintaining the catalogue

The auto-merge workflow's own allow-lists (`TRUSTED_BOT_AUTHORS`, `TRUSTED_TRIGGER_ACTORS` and `TRUSTED_REVIEW_ACTORS` in `.github/workflows/enable-auto-merge.yaml`) decide what that workflow acts on and are maintained only there; they are separate from the agents' trust gate in the monorepo `AGENTS.md`.

**Blast radius first:** a change to a composite action / reusable workflow affects **every consumer repo**. Prefer additive, backward-compatible changes; call out any breaking input/output change prominently in the PR body and treat it as a deliberate decision (keep an alias where feasible).

**Validate before any PR:** `actionlint` on every changed workflow/action (else a thorough YAML parse); confirm `uses:` refs resolve and are pinned/aligned; check `inputs`/`outputs`/`shell:` are declared; for reusable workflows keep `on: workflow_call` inputs/secrets backward-compatible. No app build here — YAML correctness + pinning is the gate. Keep all remote actions pinned to full-length commit SHAs; first-party self-references resolve by local path after the same-commit self-checkout (never a remote ref — see the self-reference rule above). Never weaken a security control to pass a check.

Read the [tested invariants](.github/agent-guides/invariants.md) before changing their implementation or self-tests.

The root instruction budget reserves 500 bytes below 32 KiB. Run the required layout check after changing this file, a guide or repository-owned workflow:

```bash
bash .github/tests/test-agent-instructions-layout.sh
```
