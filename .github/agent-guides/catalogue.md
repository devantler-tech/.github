# Catalogue layout and references

Read this guide before adding or moving catalogue components, referencing another component, or changing release conventions. Commands and code paths are relative to the repository root.

## Actions catalogue

This repository also hosts the suite's shared CI/CD building blocks: composite actions under
[`actions/`](../../actions/) and reusable `workflow_call` workflows in
[`.github/workflows/`](../../.github/workflows/). They were imported from `devantler-tech/actions` as one
snapshot (#235). The one-time importer is retired and preserved in Git history; the current
catalogue and its documentation are authored here, not generated from that historical source.
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

The default-off `inspect-release-recovery.yaml` diagnoses only public GitHub release evidence;
it cannot publish or repair channel notes. Its Go inspector lives in
`.github/scripts/inspect-release-recovery/`. Run
`bash .github/tests/test-inspect-release-recovery.sh` after changes to either surface. That suite
executes real HTTP controls and the immutable-source and read-only credential boundary, and runs
inside `test-create-release-config` in required CI. Never treat its diagnosis as completed recovery
or write authorization; #587 owns publication, legacy compatibility and protected consumer proof.

The credential-free release fixture also exercises stranded stable tags with absent or matching
default-channel notes, for both lightweight and annotated tags. It verifies no release at the tagged
commit, the next patch after a subsequent fix, and unchanged consumer files and local/remote refs.
Run `bash .github/tests/test-create-release-stable-channels.sh` for native decisions and negative
observation controls. The existing offline reusable callers run the fixture; required CI runs the
controls. This covers stable/default-branch decisions only, without the authenticated GitHub
publisher; publication, prereleases and multiple release branches need separate evidence.

```text
actions/<action-name>/            # One directory per composite action
├── action.yaml                   # Action metadata (name, description, inputs, steps)
└── README.md                     # Per-action docs (template in actions/CONTRIBUTING.md)
.scripts/                         # Scripts shared by composite actions, reached as ${GITHUB_ACTION_PATH}/../../.scripts

.github/
├── workflows/                    # ALL workflows (GitHub requires it). A workflow with `workflow_call` is a
│                                 # catalogue product; repository-owned workflows are listed below.
├── actions/                      # internal composite actions the reusable workflows check out and run
├── fixtures/                     # fixtures for the action `test-<action>` jobs
├── scripts/                      # helpers the reusable workflows run
└── tests/                        # test scripts and fixtures for the `[Test]` jobs
```

`ci.yaml` holds one `test-<action>` job per action, one `[Test]` job per reusable workflow, and this
repository's own `validate-manifests` job, all behind the single `CI - Required Checks` gate. The
catalogue's documentation is the root [README](../../README.md); each
action also has its own README.

Keep the Actions and Reusable workflows indexes parallel: a component reference and its purpose.
List organization-required compatibility sources and internal projections/fixtures separately;
neither is an invitation to add a new consumer. Each workflow's existing level-three reference
owns one `Purpose, interface and usage` collapsible, closed before the next peer heading. Keep
shared Go behavior with the main Go interface rather than accidentally nesting it under the
read-only projection. Preserve every declared input/secret table and the fail-closed parity tests.

### Self-references (read before referencing one part of the catalogue from another)

One component may reference another **in this repository**. GitHub resolves these differently — follow the matching rule:

- **CI job → local action** (e.g. a `test-<action>` job): `uses: ./actions/<action>` after `actions/checkout`. Works (the repository is checked out).
- **Reusable workflow → co-located reusable workflow:** normally
  `uses: ./.github/workflows/<x>.yaml` (same repository, same commit). An organization-required
  workflow is injected into a consumer repository, where that path resolves against the consumer
  instead; it must call a sibling workflow through a full remote reference pinned to an immutable
  commit whose workflow content has been reviewed, and every caller job is covered by a regression
  test. `validate-go-project.yaml` pins `apply-signed-fixes.yaml` in this repository that way.
  `test-required-workflow-no-local-calls.sh` requires its three callers to name one full commit of
  this repository and pins the **content**: the Git blob id of the reviewed `apply-signed-fixes.yaml`,
  which the referenced commit must carry. A release that leaves that workflow untouched therefore
  needs no edit when Dependabot bumps the callers; a release that changes it fails until the new
  workflow has been reviewed and its blob id (`git rev-parse <commit>:.github/workflows/apply-signed-fixes.yaml`)
  is recorded in the test. `test-required-workflow-no-local-calls-blocks.sh` proves each unsafe
  reference is rejected (#484).
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

1. Create `actions/<action-name>/action.yaml` and `actions/<action-name>/README.md` (template in [actions/CONTRIBUTING.md](../../actions/CONTRIBUTING.md))
2. Add a row to the Actions table in the catalogue part of [README.md](../../README.md)
3. Add a `test-<action-name>` job to `.github/workflows/ci.yaml` (`persist-credentials: false` on checkout), wired into `ci-required-checks` (both `needs:` and the inline summary step's `JOB_RESULTS` value)
4. Run `zizmor` locally before pushing


### Actionlint compatibility


`actionlint` 1.7.x does not yet recognise the `code-quality` permission scope (used by the coverage-upload jobs); that single warning is expected and not a defect.


### Repository workflows

These workflows do not declare `workflow_call`. Required CI checks this inventory against their actual triggers.

`repository-pr-admission.yaml` shares only trusted-source resolution and a read-only runner.
Each enrolled product owns `.github/actions/pr-admission/action.yaml`, with the fixed
`candidate-sha` interface, and a closed `.github/pr-admission.json` containing version `1`
and its preserved `timeout-minutes` budget. Both are loaded from GitHub's immutable product
base, never the candidate. The shared runner is not enrolled by this source preparation.
The resolver admits only the product's actual default branch, and the checkout binds directly
to GitHub's immutable base SHA. Source-only skipped checks have a different name from product
admission. The catalogue's product action reads full Git history in a bare object store and
materializes only ordinary `deploy/` blobs; candidate actions, scripts, symlinks and submodules
are never checked out. Tree reads do not apply candidate archive attributes.
Retain all existing rules until managed enrollment is published, reconciled, read back through
GitHub's API, and exercised with native positive and candidate-tampering refusal controls.

GitHub ignores activity filters for ruleset-injected workflows: only the default PR activity
types run. Do not claim `edited` revalidates required metadata; this repository retains its
existing full-CI edit feedback and manual reviewed-main metadata workflow during the migration.
See [GitHub's ruleset event documentation](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#supported-ruleset-workflow-events).
World at Ruin's runtime blocker (#1495 in that repository) still has to clear before its admission
cutover; the generic budget bound is not permission to omit tests or declare that outcome fixed.

| Workflow | Ownership |
|---|---|
| `apply-workflow-execution-policies.yaml` | This repository |
| `cd.yaml` | This repository |
| `ci.yaml` | This repository |
| `deploy-guards.yaml` | This repository |
| `governance-audits.yaml` | This repository |
| `measure-go-disk.yaml` | This repository |
| `organization-settings-audit.yaml` | This repository |
| `pr-metadata-guards.yaml` | This repository |
| `refresh-gh-digests.yaml` | This repository |
| `release.yaml` | This repository |
| `repository-admin-team-audit.yaml` | This repository |
| `repository-coverage-check.yaml` | This repository |
| `repository-drift-check.yaml` | This repository |
| `repository-pr-admission.yaml` | Shared read-only organization admission plumbing; product validators remain local |
| `stale-repository-identifier.yaml` | This repository |
| `world-at-ruin-required-regressions.yaml` | This repository |
