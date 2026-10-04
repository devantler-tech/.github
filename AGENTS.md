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
  adopted, an active `Repository` runs on `Observe`/`Create`/`Update` **without `LateInitialize`**:
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
  `Update` while keeping the enforced live value explicit. The `platform` and `ksail` Repository
  resources host workflow-built Pages sites that the GitHub App cannot write, so each declares the
  deprecated `pages` field exactly as GitHub reports it. Declaring the whole list replaces stale
  provider state and leaves no Pages diff for an update to send (issue #232). After a repository's one-time
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
manual execution requires explicit opt-in on main. Keep admission, private-diagnostic suppression,
complete-outcome reporting and source/credential mutations in required CI. Scheduled admission
is reviewed and the actual main controls pass; #395 owns scheduled observation and
rollout-flag retirement. A complete manual result does not retire legacy maintenance (#84).

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

This repository also hosts the suite's shared CI/CD building blocks: composite actions under
[`actions/`](actions/) and reusable `workflow_call` workflows in
[`.github/workflows/`](.github/workflows/). They were imported from `devantler-tech/actions` as one
snapshot (#235) by [`scripts/import-actions-catalogue.sh`](scripts/import-actions-catalogue.sh).
That repository is frozen and is archived once nothing references it (#164). Consumers reference
the catalogue here as:

```yaml
uses: devantler-tech/.github/actions/<action>@<full-commit-sha> # vX.Y.Z
uses: devantler-tech/.github/.github/workflows/<file>.yaml@<full-commit-sha> # vX.Y.Z
```

The doubled `.github` in a workflow reference is required: GitHub runs a reusable workflow only
from `.github/workflows/`, and this repository is itself named `.github`. Do not "fix" it.

The rest of this section covers the catalogue: everything under `actions/`, `.scripts/`,
`.github/actions/`, `.github/tests/`, `.github/fixtures/`, `.github/scripts/`, and every workflow
with a `workflow_call` trigger.

### Layout

```text
actions/<action-name>/            # One directory per composite action
├── action.yaml                   # Action metadata (name, description, inputs, steps)
└── README.md                     # Per-action docs (template in actions/CONTRIBUTING.md)
.scripts/                         # Scripts shared by composite actions, reached as ${GITHUB_ACTION_PATH}/../../.scripts

.github/
├── workflows/                    # ALL workflows (GitHub requires it). A workflow with `workflow_call` is a
│                                 # catalogue product; the others (ci, release, cd, deploy-guards,
│                                 # apply-workflow-execution-policies, repository-drift-check,
│                                 # repository-coverage-check, stale-repository-identifier)
│                                 # belong to this repository.
├── actions/                      # internal composite actions the reusable workflows check out and run
├── fixtures/                     # fixtures for the action `test-<action>` jobs
├── scripts/                      # helpers the reusable workflows run
└── tests/                        # test scripts and fixtures for the `[Test]` jobs
```

`ci.yaml` holds one `test-<action>` job per action, one `[Test]` job per reusable workflow, and this
repository's own `validate-manifests` job, all behind the single `CI - Required Checks` gate. The
catalogue's documentation is the root [README](README.md), between its catalogue markers; each
action also has its own README.

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

### Self-references (read before referencing one part of the catalogue from another)

One component may reference another **in this repository**. GitHub resolves these differently — follow the matching rule:

- **CI job → local action** (e.g. a `test-<action>` job): `uses: ./actions/<action>` after `actions/checkout`. Works (the repository is checked out).
- **Reusable workflow → co-located reusable workflow:** normally
  `uses: ./.github/workflows/<x>.yaml` (same repository, same commit). An organization-required
  workflow is injected into a consumer repository, where that path resolves against the consumer
  instead; it must call a sibling workflow through a full remote reference pinned to an audited
  immutable commit, and every caller job is covered by a regression test. `validate-go-project.yaml`
  pins `apply-signed-fixes.yaml` in this repository that way, and
  `test-required-workflow-no-local-calls.sh` pins the reference.
- **Composite action → shared script:** invoke via `${{ github.action_path }}/../../.scripts/…` (resolves at the calling ref, no pin). See `setup-agent-skills` / `update-agent-skills`.
- **Reusable workflow → a sibling action:** a bare `./actions/<action>` does **NOT** work (a reusable workflow resolves `./` against the *caller's* checkout). Use the **same-commit self-checkout pattern**: a step checks out `${{ job.workflow_repository }}` at `${{ job.workflow_sha }}` (the reusable workflow file's own repository + exact commit) into `path: .devantler-tech-actions`, and the next step calls `uses: ./.devantler-tech-actions/actions/<action>`. This is **zero-lag by construction** (the action always runs from the same commit as the workflow calling it) and satisfies consumer `sha_pinning_required` policies (they see only the pinned `actions/checkout` plus a local `./` path). Place the self-checkout immediately before the step that needs it, and remove it (`rm -rf .devantler-tech-actions`) before any later step that commits or scans the whole workspace (see `update-agent-skills.yaml`). **Never** use a remote self-reference — a tag pin is rejected by consumer `sha_pinning_required` policies (proven live 2026-07-03: platform's `Update Agent Skills`/`TODOs` scheduled runs failed on `devantler-tech/actions/<x>@v8.0.0`; org direction is SHA-pinning everywhere, #67), and a SHA self-pin can only ever name a *prior* release (a commit cannot embed its own SHA — an unacceptable one-release lag).
- **Composite action → a sibling composite action:** no zero-lag self-reference exists (`uses:` takes no expressions; `github.action_*` is unreliable when the action is invoked via a local path). **Inline the underlying pinned step(s)** instead of referencing the sibling wrapper — see `actions/run-dotnet-tests/action.yaml`, which inlines `upload-coverage`'s single `actions/upload-code-coverage` step — and keep the inlined inputs in sync with the wrapper.

Everything is SHA-pinned by convention and gated by `zizmor` (`unpinned-uses` policy `"*": hash-pin` — no by-owner allowances) and CodeQL's `actions/unpinned-tag`.

### Releases

This repository releases through `release.yaml`, which runs the catalogue's own
`create-release.yaml` (semantic-release) with `.releaserc`: `feat:` → minor; `fix:`/`perf:`/`revert:`
→ patch; a breaking change (`!`) → major. Other types (`ci:`, `build:`, `refactor:`, `chore:`,
`docs:`, `test:`) do not release. A catalogue change that consumers must receive promptly is
committed as `fix:` (or `feat:`), not `ci:`/`refactor:`.

### Adding a New Action

1. Create `actions/<action-name>/action.yaml` and `actions/<action-name>/README.md` (template in [actions/CONTRIBUTING.md](actions/CONTRIBUTING.md))
2. Add a row to the Actions table in the catalogue part of [README.md](README.md)
3. Add a `test-<action-name>` job to `.github/workflows/ci.yaml` (`persist-credentials: false` on checkout), wired into `ci-required-checks` (both `needs:` and the inline summary step's `JOB_RESULTS` value)
4. Run `zizmor` locally before pushing

### Adding / Changing a Reusable Workflow

#### All reusable workflows must

1. **Use the `workflow_call` trigger** — this is what makes them reusable.
2. **Pin all remote actions to commit SHAs** — `uses: owner/repo@<sha> # <version>`; first-party self-references are never remote — they resolve by local path after the same-commit self-checkout (see the self-reference rule above).
3. **Include `step-security/harden-runner`** as the first step of every job (`egress-policy: audit`).
4. **Set `permissions: {}` at the workflow top level** — grant per-job.
5. **Set `persist-credentials: false`** on `actions/checkout` unless the job pushes.
6. **Conventional commits.** Releases follow the rules under *Releases* above. A workflow/action change consumers must receive promptly is committed as `fix:` (or `feat:`), not `ci:`/`refactor:`. The reusable `create-release.yaml` product runs semantic-release with each consumer's own configuration.
7. **Document secrets and inputs** in `README.md` with usage examples.

#### Required workflow triggers

Workflows used as [org-level repository rulesets](https://docs.github.com/en/organizations/managing-organization-settings/managing-rulesets-for-repositories-in-your-organization) must also include `pull_request` and `merge_group`:

```yaml
on:
  workflow_call:
    # ... inputs/secrets
  ### Required Workflow Triggers ###
  pull_request:
  merge_group:
  ##################################
```

#### Test jobs

The queue observer reads jobs for the current run attempt with complete pagination.
It retries HTTP 5xx failures at most twice, after 2 and 4 seconds, replacing failed
output each time. Successful reads must have consistent page totals, unique job
identities, and exactly three successful queue slots belonging to that run and
attempt. Invalid or incomplete evidence fails immediately; recovery requires a
full CI rerun. The behavioral fixture and its mutation controls execute the actual
inline observer from `ci.yaml` without network access.

Actions and reusable workflows are exercised as jobs inside [`ci.yaml`](.github/workflows/ci.yaml): `test-<action>` jobs call the action via `uses: ./actions/<action>`; `[Test] <Workflow> - <Scenario>` jobs call the workflow via `uses: ./.github/workflows/<x>.yaml` with safe parameters (dry-run, fixtures from `.github/tests/` or `.github/fixtures/` — never destructive). Every new action/workflow gets a job, wired into the `ci-required-checks` job (display `CI - Required Checks`) in **two** places: the `needs:` list **and** `${{ needs.<job-id>.result }}` in the inline summary step's `JOB_RESULTS` value. `ci-required-checks` runs `if: ${{ always() }}`, holds `permissions: {}`, executes no checked-out action, and fails if any listed result is not `success` or `skipped`, so it is the single required status check — a job added to `needs:` but omitted from `JOB_RESULTS` would have its failure silently ignored. The `lint-ci-coverage-parity` job **guards this**: it fails the PR if any composite action lacks a `uses: ./actions/<action>` test job, if any reusable workflow (`workflow_call`) lacks a `uses: ./.github/workflows/<x>.yaml` test job, if `ci-required-checks.needs` and `JOB_RESULTS` name different sets of jobs, or if the gate regains a workspace-dependent step (so the silent-ignore and candidate-code footguns cannot recur). When a reusable-workflow test-job id would collide with an action's (`test-dependency-review`, `test-run-dotnet-tests`), the workflow job carries a `-workflow` suffix.

`ci-required-checks` is the sole exception to the harden-runner-first rule: adding any action would weaken its workspace-independent trust boundary. Every other step-bearing job must start with SHA-pinned `step-security/harden-runner` in audit mode, and `lint-ci-coverage-parity` enforces both sides of that contract.

**Cleanup coverage:** the production `delete-workflow-runs.yaml` wrapper is exercised
through its complete generated `delete-workflow-runs-readonly.yaml` projection. The
coverage guard accepts this pair only after `.github/tests/test-cleanup-credentials.sh`
verifies source parity, all three executed callers and their read-only permissions.
Regenerate with `bash .github/scripts/generate-cleanup-readonly.sh`; never edit the
projection by hand. Input behavior and credential restoration have independent
negative controls. Native retention/deletion fixtures remain tracked in #350.

**TODO coverage:** both TODO smoke callers use the complete generated
`scan-for-todo-comments-readonly.yaml` projection with contents-read permissions and no
App secret. Regenerate with `bash .github/scripts/generate-todo-readonly.sh`; never edit
the generated workflow. `.github/tests/test-todo-workflow-readonly.sh` verifies independent
production parity, the full job permission ceiling and both executed smoke callers before
the coverage guard accepts the production/projection pair. Existing wrapper/scanner fixtures
remain required. The contents-read-only isolated-image job runs the immutable scanner with
network access disabled and no App/project credentials. Its native negative controls retain
literal API expectations while removing TODO markers or corrupting an expected issue payload;
each must fail for its own reason, paired with healthy executions. Remaining project/authentication
coverage is tracked in #340; consumer failure handling remains in #367.

**Dependency-review comment coverage:** `test-dependency-review-comments` runs the pinned
review action through the composite against `.github/tests/fixtures/offline-github-api/main.go`, a
loopback stand-in that serves one scenario's reviewed responses, records every request and
answers anything else 404 (401 without the fixture token). A step cannot override the runner's
`GITHUB_*` values, so `.github/tests/fixtures/offline-github-env.cjs` is preloaded into the
action's own process: it points the action at the stand-in and a fixture event, refuses to
start without them, stops the process from resolving any other host, and copies what the
action prints so its errors and warnings can be checked. The preload routes the action and
detects a regression; it is not a sandbox. What keeps the test from changing anything live is
that the job holds `contents: read` and the action receives only a fixture token. Each file in
`.github/tests/dependency-review-offline/scenarios/` is one matrix leg and states the action
inputs, the responses, and what the action must produce: the complete conversation, the
outcome, the summary, and every error and warning it raises, so a failed read or write is
never silent. `dependency-review-offline.sh` starts the stand-in and checks the record. To
add a scenario, add its file and its matrix entry. `test-dependency-review-comments.sh`
rejects a matrix that differs from the scenario files, a restored write permission or
credential, and a scenario set that no longer covers every comment mode and result;
`test-dependency-review-offline.sh` exercises the stand-in, the preload and the check without
the action. A bump of the action pin that changes its conversation or its messages fails the
affected leg: read what changed in the job log before updating the scenario file.

Every `.github/tests/test-*.sh` is a test entrypoint and must have an explicit invocation in a
`ci.yaml` step's `run:` block. Put `bash .github/tests/test-name.sh` (or the executable path) in a
dedicated step without a step-level `if`; quoting, arguments, and surrounding comments or blank lines
are supported. Use portable filenames containing letters, digits, dots, underscores, and hyphens.
Explicit shells and job/workflow shell defaults must use `bash`; a custom shell could return
success without executing the test script.
Working-directory overrides at those scopes must be `.` so relative paths identify the repository's
actual test entrypoints, rather than a shadow script in a fixture directory.
The containing job may omit `if` or use CI's exact merge-group/release scheduling
exclusion; arbitrary job conditions do not count because they could silently disable the test. The
containing job has no prerequisites and appears in `ci-required-checks.needs` and `JOB_RESULTS`,
so its failure reaches the required check. Neither the job nor the step may use `continue-on-error`
except literal `false`. Keep shell control operators (`;`, `&`, `|`) out of invocation lines so test
failures reach CI. The wiring
guard rejects missing invocations and ignores step names, printed commands, heredocs, and uncalled
functions. Helper scripts use names without the
`test-` prefix and are invoked by a tested entrypoint instead of needing an exemption list.

`lint-readme-parity` also checks every reusable workflow's declared inputs and secrets against
its own level-three section in the root README. Link that section to the workflow file and put
each name in a `Secrets and Inputs`, `Inputs`, or `Secrets` table. Prose, fenced examples,
HTML comments, and another workflow's table do not count. Internal reusable workflows are
included. Run `bash .scripts/check-workflow-readme.sh` locally; its behavioral regressions live in
`.github/tests/test-workflow-readme-parity.sh`. This checks documentation presence and input/secret
classification; default values, descriptions, outputs, and reverse parity remain review concerns.

#### Shipping a new capability behind an opt-in flag (feature-flag-first)

**Release configuration warning:** `create-release.yaml` keeps `warn-missing-breaking-bang` off by default. Its inline reader inspects only unambiguous JSON without executing configuration or modifying files. `.github/tests/test-create-release-breaking-bang.sh` runs that exact reader against warning and silent fixtures and verifies the non-blocking opt-in boundary. Hosted dry-runs instantiate both flag states. Consumer rollout and flag retirement remain in devantler-tech/actions#1347; a present header pattern is not proof that release rules produce a major version.

A new job/step/behaviour must not go live for every consumer the moment it merges. Ship it as the CI analog of a release flag — an **opt-in input, default-off, backward-compatible** — so it can be validated on a few callers before broad rollout (the portfolio-wide **feature-flag-first delivery** contract in the monorepo `AGENTS.md`; [monorepo#2059](https://github.com/devantler-tech/monorepo/issues/2059)):

1. **Declare the gate** on the reusable workflow / composite action: `inputs.<enable-x>: { type: boolean, default: false }` (composite-action inputs are always strings, so use `default: 'false'`).
2. **Guard the new job/step** with `if: ${{ inputs.<enable-x> }}`. Existing callers that omit the input get `false` → **zero behaviour change**; only callers that pass `true` opt in.
3. **Roll out caller-by-caller**, then **flip the default to `true`** once proven, then **remove the input** when the capability is unconditional. A release flag is short-lived — no permanent dead inputs (file the removal when the flag is born; long-lived is only for kill-switch/permissioning gates).

**Gotchas:**

- `workflow_dispatch` passes booleans as **strings** while `workflow_call` passes real **booleans** — a workflow triggered by both must normalize before comparing: `if: ${{ inputs.<enable-x> == true || inputs.<enable-x> == 'true' }}`.
- You **cannot** wrap `if:` around an individual `with:` input — gate the whole **step** (or **job**), or select the value with a ternary in the `with:` value (`${{ inputs.<enable-x> && 'a' || 'b' }}`).
- **Test both states.** Per the feature-flag-first "test both states" rule, cover the flag **off** (default) and **on** with `[Test]` jobs (see *Test jobs* above) — a flag whose off-path is untested can regress silently.

**Workflow-file fixes:** `manual-workflow-fixes` defaults to false in both lint workflows. Opted-in
runs export the full patch but withhold automatic signing when any changed path is under the
repository-root `.github/workflows/`. Keep mixed edits and renames
in one downloadable artifact, with a warning explaining local application. Do not widen the signer's
token permissions to apply them. `test-lint-workflow-fixes.sh` exercises both exporters against real
Git fixtures in both flag states, including binary edits, mode changes, additions, deletions, renames,
and ordinary paths. Eligible opted-in runs recover patches after lint errors without making the
failed job successful; cancelled runs do not force recovery. `test-lint-recovery-gates.sh` exercises
the status and eligibility boundaries. Omitted/false inputs preserve prior routing. Both flag states
must remain instantiated in CI, and the read-only failure and credential-boundary tests remain green.
Consumer rollout and flag removal are tracked in devantler-tech/actions#1186.

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

**Production to-do input forwarding:** the reusable scanner exposes the composite's
optional-project integration choices while retaining its existing defaults.
The generated read-only workflow runs the exact production steps with an empty
project and all paths excluded in required CI; both offline dry-run calls remain.
Keep default/forwarding controls, projection parity and all three caller boundaries
covered. This proves the no-project wrapper path; #340 still owns live project
association, consumer rollout and flag retirement. The separately generated default
fixture retains the production defaults and native conditional routing, with only
offline dependencies. Keep both its compatibility caller and missing-token control
required; this fixture never proves live token generation or project association.

**Verified publication:** Opted-in publishers authenticate and establish normalized version absence before staging and again before promotion. Preserve structured missing-version evidence, fail-closed authentication/read errors, both application targets, immutable helper checkout and removal before the image build. Serialize opted-in publishers for the same target within a caller repository with a shared concurrency group, queue:max and no cancellation. Keep `.github/tests/test-unpublished-version.sh`, promotion controls and the native disposable-registry proof in required CI. Other writers can race the final check; registry tag writes are not atomic across repositories. #371 owns default-path and consumer rollout.

**Manifest naming:** `validate-naming` runs by default using the caller's versioned
configuration. An explicit `enabled: "false"` skips configuration reads and setup.
Keep the omitted-input Linux/macOS fixtures, seeded-violation failure and opt-out
boundaries required in CI. .github#274 owns consumer cleanup and input retirement.

**Shell pipeline assertions:** `lint-shell-pipelines` invokes the shared guard with
`enabled: true` over the real script directories declared in that CI job's
`SCAN_PATHS`. Keep new script-owning directories in this scope and extend
`.github/tests/test-shell-pipeline-adoption.sh` with a representative script.
The test proves each scope rejects a deliberate regression without executing the
scanned scripts. Intentionally invalid product fixtures stay in `.github/fixtures`
and are exercised separately. Repair findings by checking producer completion
before searching captured output; do not blanket-exempt the repository's scripts.
The shared action validates by default, including when callers omit `enabled`.
An explicit `enabled: "false"` skips setup and discovery. Linux/macOS fixtures cover
omitted-input clean, unsafe and malformed scans; .github#268 owns consumer adoption
and the later removal of the temporary opt-out input.

**Retired repository links:** `validate-retired-repo-links` is a default-off,
read-only Go validator with no module dependencies. Keep both flag states, real
good/bad action fixtures on Linux/macOS, and the required-check wiring covered.
Configuration belongs to each consumer; never hard-code retired portfolio names
or blanket historical exemptions in the action. Exceptions require an exact
file, repository and reason. Consumer adoption and flag retirement are in devantler-tech/actions#1350.

```bash
# Run yamllint
yamllint .github/workflows/

# Check action/workflow pinning with zizmor
zizmor --config zizmor.yml .github/workflows/

# Lint workflows (if installed)
actionlint
```

`actionlint` 1.7.x does not yet recognise the `code-quality` permission scope (used by the coverage-upload jobs); that single warning is expected and not a defect.

### Maintaining the catalogue

The auto-merge workflow's own allow-lists (`TRUSTED_BOT_AUTHORS`, `TRUSTED_TRIGGER_ACTORS` and `TRUSTED_REVIEW_ACTORS` in `.github/workflows/enable-auto-merge.yaml`) decide what that workflow acts on and are maintained only there; they are separate from the agents' trust gate in the monorepo `AGENTS.md`.

**Blast radius first:** a change to a composite action / reusable workflow affects **every consumer repo**. Prefer additive, backward-compatible changes; call out any breaking input/output change prominently in the PR body and treat it as a deliberate decision (keep an alias where feasible).

**Validate before any PR:** `actionlint` on every changed workflow/action (else a thorough YAML parse); confirm `uses:` refs resolve and are pinned/aligned; check `inputs`/`outputs`/`shell:` are declared; for reusable workflows keep `on: workflow_call` inputs/secrets backward-compatible. No app build here — YAML correctness + pinning is the gate. Keep all remote actions pinned to full-length commit SHAs; first-party self-references resolve by local path after the same-commit self-checkout (never a remote ref — see the self-reference rule above). Never weaken a security control to pass a check.

**Tested invariants (don't silently regress):** some behaviours of a workflow are a *contract* consumers depend on, not an implementation detail — `validate-go-project.yaml`'s vuln-scan honoring a `.govulncheck-allow.txt` allowlist is the canonical one (it was silently lost across `v5.4.1`–`v5.4.4` when the gate swapped to an action with no `allow-file` input, wedging every consumer that had risk-accepted an advisory). These contracts are guarded by self-tests in `ci.yaml` (`test-govulncheck-allowlist-honored` / `test-govulncheck-strict-blocks` / `test-govulncheck-action-lockstep`, against the `.github/tests/govulncheck-allowlist/` fixture). **Any swap of the vuln-scan implementation — including back to the official `golang/govulncheck-action` once it gains an `allow-file`-equivalent input — must keep that guard green**; update the self-test in lockstep, never delete it to make a swap pass.

**Scanner compatibility and verdicts:** the workflow now resolves `.github/actions/govulncheck` from its own exact commit. That internal action owns the single reviewed scanner-version pin and the allowlist evaluator. Hosted strict and allowlisted fixtures cover Go 1.25, 1.26, and 1.27, including a generic method-set regression that crashes the old scanner. The strict fixture must report `verdict=blocking` and the expected advisory; an operational error has no verdict and must never count as a successful negative test. `test-govulncheck-scan.sh` covers result parsing and failure boundaries, and `test-govulncheck-wiring.sh` keeps the production and fixture implementations aligned.

**Vulnerability-scan timeout retry (tested invariant):** a job that hits its own `timeout-minutes` ends `cancelled`, and a cancelled required check is never rerun on a Dependabot PR, so auto-merge waits forever (devantler-tech/actions#1097). `validate-go-project.yaml`'s scan step therefore carries its own deadline with `continue-on-error`, a classifier step retries it exactly once when the elapsed time shows it ran out of time (first stopping the timed-out `govulncheck`, which a step timeout leaves running as an orphan), and fails the job at once on any other outcome (a finding is never retried). The job ceiling covers two attempts plus setup-go's post-job cache save, so it cannot pre-empt the retry. `test-govulncheck-timeout-retry.sh` pins the structure and drives the classifier, `test-govulncheck-timeout-retry-blocks.sh` proves each assertion fires, and the `test-govulncheck-timeout-retry-live` job proves GitHub's step-timeout semantics on a step that deliberately outlives a 1-minute deadline, including that its child process survives the step and is stopped before the retry. Keep the scan and retry steps' `uses`/`with`/`timeout-minutes` identical.

**Signed auto-fixes are ON by default, including the org-required direct run (tested invariant):** `validate-go-project.yaml` gates every fixer export and apply job on ONE decision, `needs.changes.outputs.signed-fixes` — `inputs.apply-signed-fixes == true || (toJSON(inputs) == '{}' && contains(github.workflow_ref, '/.github/workflows/validate-go-project.yaml@'))`. The second clause is load-bearing: outside `workflow_call` the `inputs` context is EMPTY, so a gate written on the input alone can never enable the org-required direct run — the one path that produces auto-fix commits on `ksail` — and no `default:` reaches it (measured on devantler-tech/actions#1129: direct run `inputs={}` with its own path in `workflow_ref`; a called run carries every declared input and the CALLER's ref — the empty-inputs half is what keeps an explicit `false` honoured, since null, false and '' compare equal). ⚠️ The direct path's EFFECT is proven only by ksail's first Go pull request after the pin bump; devantler-tech/actions#1129 proved the signer through workflow_call. `.github/tests/test-validate-go-signed-fixes-contract.sh` pins the decision expression, the `true` default, `needs: changes` on every apply job, and both states instantiated in `ci.yaml` (`apply-signed-fixes: false` on the read-only self-tests). A caller opts out with `apply-signed-fixes: false`; never re-gate on the raw input (devantler-tech/actions#1075).

**Shared Go fix exporter (tested invariant):** The three Go fixer lanes resolve `.github/actions/prepare-fixes` from the workflow's exact commit. The composite removes its reserved helper checkout before capturing a complete, root-relative patch. Each caller supplies its existing upload eligibility decision once and reuses the returned decision for read-only failure. Keep the real-Git patch replay, recovery-gate mutations, and hosted `test-prepare-fixes` scenarios green when changing this boundary. Manual workflow patches remain complete and never authorize a signing job.

**Catalogue self-test credentials:** Required CI follows every declared CI job through its
reusable workflows and local composite actions. A possibly reached leaf has no repository-write
authority or external secret; reporting permissions and read-only OIDC proofs remain classified
separately. Dry-run and skipped-dependency proofs use call-specific inputs and complete source
observations. Action metadata has one regular-file implementation, bound to the actual immutable
checkout through verified commit/tree/blob identities. Missing, mutable or
unclassified sources and partial expression evidence fail closed as UNKNOWN. Keep both
`test-catalogue-credentials.sh` and its real-source mutation controls unconditional within
`lint-ci-coverage-parity`, whose result gates the required check. This admission guard does not
prove the cleanup selector behavior still tracked in #350 or replace individual user-path tests.

**Fixer-lane credential boundary (tested invariant):** `validate-go-project.yaml`'s three fixer lanes (`tidy`, `golangci-lint`, `lint` — every job that exports `fixes-created`) run tooling configured by the pull request under review, so they hold no credential that can write to the branch: `contents: read`, no App-token step, no App private key, no secret other than `GITHUB_TOKEN` (every expression spelling, case-insensitively, matched on complete scalars, and including the workflow-level `env:` every job inherits), and `persist-credentials: false` on every checkout. The commit is made on a fresh runner by `apply-signed-fixes.yaml`. `ci.yaml` asserts this with `.github/tests/test-fixer-credential-boundary.sh` (workflow- and job-scoped, so `lint.yaml` reuses it) and proves each assertion fires for its own reason with `test-fixer-credential-boundary-ablation.sh`; the lane list is derived from the workflow, so a new fixer lane is covered by construction. **A lane reshape must keep that guard green** — never move a write credential back into a fixer lane to make a step simpler.

**gh installer digest pinning (tested invariant):** `.scripts/ensure-gh-skill.sh` verifies a downloaded cli/cli archive against `.scripts/gh-release-digests.tsv`, a reviewed version-to-digest manifest, in addition to attestation and the release-served checksum. That manifest is the only gate that rejects a **same-or-newer** substituted archive: attestation cannot tell cli/cli releases apart, the checksums file ships from the same mutable release, and the post-install version assertion is a floor rather than an equality. Enforcement is per row — an unpinned version warns and falls through, so a consumer passing a custom `gh-version` is never blocked. `test-ensure-gh-skill-script` guards it (cases 8e–8j: substitution rejected, matching digest installs, unpinned warns, malformed row fails closed); keep those green and refresh rows with `bash .scripts/refresh-gh-digests.sh <version>` rather than by hand.

**Failure-mode coverage for gating workflows (the convention):** every **gating** reusable workflow — one whose job is to *fail a PR on bad input* — carries **both** a *passes-on-good-input* and a *blocks-on-bad-input* self-test, because a happy-path test alone cannot catch a gate that silently stopped biting. The pattern (per `test-govulncheck-strict-blocks` and `test-zizmor-blocks`): point the gate's **own** action — pinned to the **same SHA**, guarded by a `*-action-lockstep` check — at a deliberately-bad fixture under `.github/tests/`, `continue-on-error`, then assert the run *failed* **and** reported the expected finding (so an operational error can't false-pass). The fixture lives **outside** the gate's own scan scope (e.g. `.github/tests/zizmor-fixture/` is outside `.github/workflows/`) so it never trips the real gate. **Non-gating** workflows (release/publish/deploy dry-runs, `delete-workflow-runs`, `enable-auto-merge`, `template-sync`, `sync-cluster-policies`, `update-agent-skills`, `scan-for-todo-comments`) have no "bad input" to reject, so a happy-path `[Test]` job is complete coverage. Where a clean failure-mode fixture is genuinely impractical, record the reasoned gap rather than forcing a fragile test: the `dependency-review` workflow needs a PR diff introducing a bad dependency, so its blocking path is replayed at the action level by the offline `on-failure-vulnerable` scenario (see *Dependency-review comment coverage*) rather than through the workflow.

**Applied-fixes failure handling (tested invariant):** the signer requires a valid head-commit message before deciding that a signature check is unnecessary. Failed Git headline or head-identity reads fail the job before a commit request. `test-apply-signed-fixes-behavior.sh` executes the workflow's actual inline steps against disposable Git repositories and an offline API fixture, covering both signature paths, exact payload bytes, expected-head binding, no-change and replacement runs, patch conflicts, and operational errors. Changes are committed to a temporary branch identified by the check-run ID; only an exact signed commit with the original head as its single parent can advance the consumer branch. One atomic, non-forced ref transaction compares both tips and deletes the staging ref. Cleanup deletes only an acknowledged staging tip and retains uncertain or concurrently changed refs. Temporary branches can trigger ordinary consumer workflows; cancellation can leave a ref requiring later inspection. Its ablation suite detects missing verification, removed expected heads, blind cleanup, forced updates and softened read failures. Test helpers stay outside the consumer tree; the privileged job still executes no checked-out code.

**Task menu** (1–2 items/run; high care):

The catalogue-owned `refresh-gh-digests.yaml` updater runs only from reviewed main, validates the
complete manifest before minting a repository-scoped App token, and opens a signed draft limited
to the manifest. Preserve its source/credential/path mutations and the fail-closed retained-pin
regression. The read-only native CI preparation supplies actual release checksums; it is not
proof that a draft update merged or that a consumer installed the reviewed pinned archive.

- **Triage** new issues/PRs; one insightful comment on the oldest un-commented item.
- **Action/version hygiene:** keep third-party actions pinned & aligned; bundle Dependabot `github_actions` PRs; flag majors. (There are no first-party self-reference pins to bump — self-references resolve via the same-commit self-checkout.)
- **Workflow health & dedup:** consolidate duplicated steps, split overgrown jobs, improve caching, remove dead workflows — backward-compatible, one concern per draft PR, `actionlint`-clean.
- **Consistency** between actions and reusable workflows and with how consumer repos call them.
- **Maintain your own PRs:** fix CI you caused, resolve conflicts.
