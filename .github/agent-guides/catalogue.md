# Catalogue layout and references

Read this guide before adding or moving catalogue components, referencing another component, or changing release conventions. Commands and code paths are relative to the repository root.

## Actions catalogue

This repository also hosts the suite's shared CI/CD building blocks: composite actions under
[`actions/`](../../actions/) and reusable `workflow_call` workflows in
[`.github/workflows/`](../../.github/workflows/). They were imported from `devantler-tech/actions` as one
snapshot (#235). The one-time importer is retired and preserved in Git history; the current
catalogue and its documentation are authored here, not generated from that historical source.
That repository was deleted after verified migration and retirement (#240); historical signer
identities remain verification data, never executable dependencies. Consumers reference the
maintained catalogue here as:

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

The same Go module holds a separate `cmd/publish-release-recovery` command. Only the default-off
repository-owned manual `publish-release-recovery.yaml` calls it, after a confirmed dispatch, a read-only
admission and only then a writer token; run `bash .github/tests/test-publish-release-recovery.sh`
after changing it. It re-runs the inspector's admission with its writer credential, so the inspection command
stays read-only. It refuses to publish unless that credential can push, two complete release
inventories agree, no draft names the tag (or no tag), and a second admission matches the first. It
then sends exactly one create-release request: the existing tag, the honest recovery receipt, no
generated notes or assets, and `make_latest` as the JSON string `"false"`. Afterwards it reads back
the release (every requested field), the tag, the source, the inventory and the latest release
independently, and its result reports only what it observed. A matching publication is a no-op
that claims nothing it did not check. It never retries a write. A server
error, a lost connection or a failed readback is reported as an unknown outcome, naming any release
it created, and a later run reconciles it through fresh reads.

No production consumer adopted this recovery workflow. It is not a public reusable interface:
other products own their recovery workflow until real repeated use justifies extraction.
`release-recovery-offline-fixture.yaml` is an internal generated projection containing only the
complete credential-free offline job, with no publisher job or secret interface. Regenerate it
with `bash .github/scripts/generate-release-recovery-fixture.sh`; the independent production
parity, generator equality, native enabled/disabled controls and omission mutations stay required.

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
├── workflows/                    # ALL workflows (GitHub requires it). Public `workflow_call` products
│                                 # and explicitly internal generated fixtures are indexed separately.
├── actions/                      # internal composite actions the reusable workflows check out and run
├── fixtures/                     # fixtures for the action `test-<action>` jobs
├── scripts/                      # helpers the reusable workflows run
└── tests/                        # test scripts and fixtures for the `[Test]` jobs
```

`ci.yaml` holds one `test-<action>` job per action, one `[Test]` job per reusable workflow, and this
repository's own `validate-manifests` job, all behind the single `CI - Required Checks` gate. The
catalogue's documentation is the root [README](../../README.md); each
action also has its own README.

Keep the Actions and Reusable workflows indexes parallel: reference, purpose and executable source,
each inside one `Browse available interfaces` collapsible. Action references own their per-action
READMEs; workflow references have stable explicit anchors in the root README. Do not copy their
interface tables into the indexes.
List organization-required compatibility sources and internal projections/fixtures separately;
neither is an invitation to add a new consumer. Each workflow's existing level-three reference
owns one `Purpose, interface and usage` collapsible, closed before the next peer heading. Keep
shared Go behavior with the main Go interface rather than accidentally nesting it under the
read-only projection. Preserve every declared input/secret table and the fail-closed parity tests.

### Self-references (read before referencing one part of the catalogue from another)

One component may reference another **in this repository**. GitHub resolves these differently — follow the matching rule:

- **Native same-repository references:** `uses: $/actions/<action>` (or
  `$/.github/workflows/<workflow>.yaml`) binds to the repository and commit of the
  **file containing that reference**, independently of the consumer's workspace.
  A nested composite therefore keeps its own pinned source, not the caller workflow's
  potentially newer revision. No `@ref` suffix or source checkout is needed. GitHub.com
  runners must be at least 2.336.0; see the [GitHub announcement](https://github.blog/changelog/2026-07-30-reference-same-repository-actions-with-self-repository-syntax/).
  The private .NET fixture helper uses this form in native CI and nested composition.
  Preserve the credential graph's defining-file revision and refusal controls.
- **CI job → workspace action:** existing `uses: ./actions/<action>` references require
  `actions/checkout`. They resolve from workspace bytes, not the defining file; the
  broader native-reference migration and its cross-repository proof are tracked in #271.
- **Reusable workflow → co-located reusable workflow:** new calls use native
  `uses: $/.github/workflows/<x>.yaml` (the defining file's repository and commit).
  Existing classic `./.github/workflows/` calls retain their source-boundary controls during #271.
  An organization-required
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
- **Composite action → shared script:** invoke via `${{ github.action_path }}/../../.scripts/…` (resolves at the calling ref, no pin). Skill maintenance actions are published independently and resolve scripts within their own repositories.
- **Reusable workflow → a sibling action:** native `$/actions/<action>` uses the workflow's
  own source. Existing same-commit self-checkouts bind `${{ job.workflow_repository }}`
  and `${{ job.workflow_sha }}` into `.devantler-tech-actions` before a workspace-relative
  call. Keep their exact identity and cleanup until their #271 migration is proven.
  A tag self-reference is not SHA-pinned; a remote SHA self-pin necessarily names an
  earlier commit, so neither substitutes for exact same-commit composition.
- **Composite action → a sibling composite action:** native `$/actions/<action>` keeps
  the defining composite's repository and exact commit, without workspace lookup.
  Existing intentionally inlined external steps retain their reviewed inputs.
- **Actions from another reviewed source:** `./` is still needed when the job deliberately
  checks out a *different* product's immutable reviewed base (for example product admission).
  Do not replace those paths with `$/`: that would select the runner workflow's own
  repository instead of the product validator. Check the source identity, not just spelling.

The catalogue's private `.github/actions/test-dotnet-fixture` helper is only called by this
repository's native CI jobs, not exported as a consumer interface. Its known catalogue workflow
identity supplies native same-commit actions outside the consumer workspace. Its
isolation test deliberately places complete catalogue source, including unrelated projects
and coverage, in a separate action cache and proves an in-workspace copy still fails.
Keep the credential, source-state, three-OS and selector refusal controls when changing it.

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
Enrollment covers monorepo, this configuration repository and World at Ruin. Their product-owned validators and
repository-bound executed results replace the disabled singleton organization associations after
native positive and tampering-refusal controls (#693). The unused World-only catalogue source
and resolver are retired after native controls also passed with its old rule inactive;
World retains its own evaluator and containment helpers. New enrollments require the same live proof
before retiring their old gate. A broken reviewed source uses the maintainer-owned recovery procedure in
[Maintenance](../../AGENTS.md#maintenance), never a candidate-controlled fallback or an automatic protection bypass.
Each enrolled product owns `.github/actions/pr-admission/action.yaml`, with the fixed
`candidate-sha` interface, and a closed `.github/pr-admission.json` containing version `1`
and its preserved `timeout-minutes` budget. Both are loaded from GitHub's immutable product
base, never the candidate.
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
The maintainer explicitly decoupled World at Ruin's workflow ownership cleanup from its independent
runtime target (#1495 in that repository). Keep that performance issue open until its own measurements
pass; the generic budget bound is not permission to omit tests or declare that outcome fixed.

| Workflow | Ownership |
|---|---|
| `apply-workflow-execution-policies.yaml` | This repository |
| `cd.yaml` | This repository |
| `ci.yaml` | This repository |
| `deploy-guards.yaml` | This repository |
| `governance-audits.yaml` | This repository |
| `inspect-release-recovery.yaml` | This repository; default-off manual diagnosis, not a reusable consumer interface |
| `measure-go-disk.yaml` | This repository |
| `organization-settings-audit.yaml` | This repository |
| `pr-metadata-guards.yaml` | This repository |
| `publish-release-recovery.yaml` | This repository; default-off confirmed manual recovery, not a reusable consumer interface |
| `release.yaml` | This repository |
| `repository-admin-team-audit.yaml` | This repository |
| `repository-coverage-check.yaml` | This repository |
| `repository-drift-check.yaml` | This repository |
| `repository-pr-admission.yaml` | Shared read-only organization admission plumbing; product validators remain local |
| `stale-repository-identifier.yaml` | This repository |
