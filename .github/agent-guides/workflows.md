# Workflow and CI contracts

Read this guide before changing catalogue implementations, tests or workflows. Read the [catalogue reference rules](catalogue.md) alongside it. Commands and code paths are relative to the repository root.

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

Publication safety fixtures run in the independent always-on `test-publish-contracts` job,
alongside catalogue guards. Both jobs feed the required reducer; publication coverage retains
the contents-read ceiling, synthetic credentials and disposable native registry controls.

The queue observer reads jobs for the current run attempt with complete pagination.
It retries HTTP 5xx failures at most twice, after 2 and 4 seconds, replacing failed
output each time. Successful reads must have consistent page totals, unique job
identities, and exactly three successful queue slots belonging to that run and
attempt. Invalid or incomplete evidence fails immediately; recovery requires a
full CI rerun. The behavioral fixture and its mutation controls execute the actual
inline observer from `ci.yaml` without network access.

Actions and reusable workflows are exercised as jobs inside [`ci.yaml`](../../.github/workflows/ci.yaml): `test-<action>` jobs call the action via `uses: ./actions/<action>`; `[Test] <Workflow> - <Scenario>` jobs call the workflow via `uses: ./.github/workflows/<x>.yaml` with safe parameters (dry-run, fixtures from `.github/tests/` or `.github/fixtures/` — never destructive). Every new action/workflow gets a job, wired into the `ci-required-checks` job (display `CI - Required Checks`) in **two** places: the `needs:` list **and** `${{ needs.<job-id>.result }}` in the inline summary step's `JOB_RESULTS` value. `ci-required-checks` runs `if: ${{ always() }}`, holds `permissions: {}`, executes no checked-out action, and fails if any listed result is not `success` or `skipped`, so it is the single required status check — a job added to `needs:` but omitted from `JOB_RESULTS` would have its failure silently ignored. The `lint-ci-coverage-parity` job **guards this**: it fails the PR if any composite action lacks a `uses: ./actions/<action>` test job, if any reusable workflow (`workflow_call`) lacks a `uses: ./.github/workflows/<x>.yaml` test job, if `ci-required-checks.needs` and `JOB_RESULTS` name different sets of jobs, or if the gate regains a workspace-dependent step (so the silent-ignore and candidate-code footguns cannot recur). When a reusable-workflow test-job id would collide with an action's (`test-dependency-review`, `test-run-dotnet-tests`), the workflow job carries a `-workflow` suffix.

`ci-required-checks` is the sole exception to the harden-runner-first rule: adding any action would weaken its workspace-independent trust boundary. Every other step-bearing job must start with SHA-pinned `step-security/harden-runner` in audit mode, and `lint-ci-coverage-parity` enforces both sides of that contract.

**Cleanup coverage:** the production `delete-workflow-runs.yaml` wrapper is exercised
through its complete generated `delete-workflow-runs-readonly.yaml` projection. The
coverage guard accepts this pair only after `.github/tests/test-cleanup-credentials.sh`
verifies source parity, all three executed callers and their read-only permissions.
Regenerate with `bash .github/scripts/generate-cleanup-readonly.sh`; never edit the
projection by hand. Input behavior and credential restoration have independent
negative controls. The owned Go driver under `.github/scripts/delete-workflow-runs/`
completes enumeration and individual orphan-parent revalidation before mutation,
freezes run creation time and partitions searches at GitHub's 1,000-result cap
(the whole history splits off its latest day first, then halves every other range),
requires every split to recover its own advertised minimum before deletion,
uses the complete repository snapshot for every workflow's retention decisions,
retries transient reads twice and never replays a deletion. Changed page totals
permit one fresh run inventory with the original cutoff and shared partition and
rate-limit wait budgets. Newly observed workflows
retain their runs; unknown absence fails closed. Its real HTTP and native-command tests run through the same
coverage guard, including retention, pagination, partial reads, ambiguous identities,
lost mutation responses and rejected or unconfirmed deletions. Fixtures use only
synthetic credentials; all three hosted callers retain read-only permissions.

**TODO coverage:** both TODO smoke callers use the complete generated
`scan-for-todo-comments-readonly.yaml` projection with contents-read permissions and no
App secret. Regenerate with `bash .github/scripts/generate-todo-readonly.sh`; never edit
the generated workflow. `.github/tests/test-todo-workflow-readonly.sh` verifies independent
production parity, the full job permission ceiling and both executed smoke callers before
the coverage guard accepts the production/projection pair. Existing wrapper/scanner fixtures
remain required. The contents-read-only isolated-image job runs the immutable scanner with
network access disabled and synthetic issue/project credentials. The production Go supervisor
requires complete REST/GraphQL evidence, latches failures before subsequent writes, and never
replays the scanner after a mutation attempt. Its native negative controls retain
literal API expectations while removing TODO markers or corrupting an expected issue payload;
each must fail for its own reason, paired with healthy executions. Supervisor race tests cover
concurrent authorization and lost mutation responses. Workflow authentication and consumer
rollout coverage remain in #340.

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
never silent. Scenario admission rejects duplicate keys and constraints HTTP cannot serve;
malformed request queries never receive a reviewed response. Recording failures stop the server.
`dependency-review-offline.sh` requires a clean completion receipt bound to the start identity
and complete scenario/record bytes, and validates integral route indices and declared statuses. To
add a scenario, add its file and its matrix entry. `test-dependency-review-comments.sh`
rejects a matrix that differs from the scenario files, a restored write permission or
credential, and a scenario set that no longer covers every comment mode and result;
`test-dependency-review-offline.sh` exercises the stand-in, the preload and the check without
the action. A bump of the action pin that changes its conversation or its messages fails the
affected leg: read what changed in the job log before updating the scenario file.

**Default-branch Go maintenance:** `maintenance-default-branch` defaults to true
after the KSail pilot and complete caller inventory. Explicit false remains the
rollout rollback. Tidy and dead-code findings fail read-only validation without
default-branch writes. Keep inherited-default and explicit-opt-out callers,
renamed branches, PR/feature routing, merge-queue exclusions and actual finding
rejection covered. Final input and concurrency-discriminator removal remain #276.

**Go module selection:** Validation reads one complete tracked-file inventory.
Explicit `working-directory` calls keep their selected module; empty called inputs
select the repository root. Input-free required runs prefer a tracked root module,
otherwise require exactly one tracked nested module. Missing, conflicted, linked,
unsafe and ambiguous selections fail without publishing a directory. All eight
validation jobs, toolchain readers and cache identities use the same resolved
directory. The resolver comes from the workflow's immutable source and is removed
before consumer validation. Existing non-Go skips remain skips. Keep
`test-go-module-resolution.sh` and the generated read-only projection passing.

**Go compilation caches:** Test and race coverage retain separate `GOCACHE` archives,
keyed by job, runner OS/architecture, installed Go version, working directory and that
module's `go.mod`/`go.sum`. An exact compiler-cache hit reuses build outputs; both
original test commands still run and Go validates their inputs. Save only on the default
branch, after success on a cache miss, without broad restore prefixes. Keep
`test-go-build-cache.sh` and the read-only workflow projection passing.

**Disposable PostgreSQL fixtures:** Called validation defaults off; input-free
required runs opt in only through a regular tracked module-local closed-schema
declaration. Immutable catalogue code accepts bounded namespace/database data,
not endpoints, credentials, SQL or commands. Test and Coverage each start their own
fixed digest-pinned PostgreSQL 17 service with separate restricted roles. Observe the
job's exact service identity and state before provisioning. Recover only a cleanly
stopped bound service, once before SQL; failed or unproven states are refused.
After runner initialization, check the final TCP server; provisioning waits within
a fixed bound and executes its SQL batch once. Publish fixture URLs only after
success, and remove helper checkout before Go execution. Opted-in runs disable
cached test verdicts while retaining full test scopes and race/coverage settings.
Keep declaration/refusal controls, actual service bindings and native database/role
controls required; preserve the inert omitted/false called state. Pilot adoption
and release-gate retirement remain #573.

**Go module cache:** setup-go's own cache is off in every Go job and in the internal
`govulncheck` action, because it saves a multi-gigabyte archive from any ref whose key
misses. Each job restores one module archive keyed by runner OS/architecture, working
directory and that module's `go.sum`; the default branch's Test job is its only writer.
A pull request falls back to the default branch's newest archive and never writes one.
The default branch restores an exact match only, so its archive cannot accumulate retired
module versions. A new job that sets up Go needs the same two restore steps and no save.
Keep `test-go-module-cache-policy.sh` passing (#565).

Required catalogue CI also observes the dependency-bearing PostgreSQL caller's
current run attempt (#570). It reads complete job pages and all eight Go action
logs, rejects skipped restores and PR Go-cache writes (including implicit
setup-go saves), and requires one non-empty exact main module archive after a
save or an exact hit without another save. The observer and fixture are selected
together and neither may become optional; keep their offline failure controls
and required-result wiring intact. Organization-required consumer invocation
and the whole-repository cache-budget outcome remain separate evidence on #565.

**Go disk measurement:** `measure-disk-usage` defaults to false. Opted-in build,
test and race coverage emit separate cleanup and Go-command receipts, including
capacity before and after cleanup and 1-second sampled headroom. Measurement
does not change the selected cleanup policy or command results. Failed or incomplete observations make every capacity
field null with status `unknown`. The helper checkout is removed before consumer
commands run; cancellation stops the command process group and sampler. The
read-only projection admits Go for selected catalogue fixture callers even on
workflow-only diffs; production and other consumers retain their Go path filter. Keep
`test-go-disk-measurement.sh` and the generated read-only projection passing.
The optional `minimum-free-disk-gib` budget defaults to zero (unconditional cleanup).
A complete bounded capacity read can retain toolchains only when the opted-in budget
is met; unknown capacity retains reclamation. Keep `test-go-disk-cleanup.sh` passing.
The default-off, reviewed-main `measure-go-disk.yaml` evaluation uses a pinned public
KSail baseline with read-only authority. Production budgets and broader rollout remain in #527.

Every `.github/tests/test-*.sh` is a test entrypoint and must have an explicit invocation in a
`ci.yaml` step's `run:` block. Put `bash .github/tests/test-name.sh` (or the executable path) in a
dedicated step without a step-level `if`; quoting, arguments, and surrounding comments or blank lines
are supported. Use portable filenames containing letters, digits, dots, underscores, and hyphens.
Explicit shells and job/workflow shell defaults must use `bash`; a custom shell could return
success without executing the test script.
Working-directory overrides at those scopes must be `.` so relative paths identify the repository's
actual test entrypoints, rather than a shadow script in a fixture directory.
The containing job may omit `if` or use CI's exact merge-group/release scheduling
exclusion, optionally followed by the exact positive current-job membership test
in `needs.select-ci-tests.outputs.selected`; arbitrary job conditions do not count
because they could silently disable the test. The containing job has no prerequisites
except that exact selector contract and appears in `ci-required-checks.needs` and `JOB_RESULTS`,
so its failure reaches the required check. Neither the job nor the step may use `continue-on-error`
except literal `false`. Keep shell control operators (`;`, `&`, `|`) out of invocation lines so test
failures reach CI. The wiring
guard rejects missing invocations and ignores step names, printed commands, heredocs, and uncalled
functions. Helper scripts use names without the
`test-` prefix and are invoked by a tested entrypoint instead of needing an exemption list.

**Affected catalogue selection:** The read-only `select-ci-tests` job checks the complete
job inventory and immutable full-history Git diff before allocating 79 independently
gated test jobs. Recognized action-owned paths narrow that set, including reviewed
transitive caller and inline-lockstep ownership. The cleanup workflow and its
generated read-only projection have exact file ownership bound to all three native
callers; their admission stays intact, and affected callers must succeed in the
required reducer. Ordinary regular-file modifications to `run-dotnet-tests.yaml`
select its normal native caller, hosted helper-checkout proof and credential
lockstep control. All four reviewed dependencies must retain exact ownership,
including the separately admitted authenticated caller; an unreviewed caller or
missing owner fails validation. Additions, deletions, type changes and unclassified
rename destinations keep full coverage. The authenticated caller's original
event/author admission remains outside mandatory execution selection.
Shared helpers, other workflows, tests,
fixtures, root configuration and unknown paths retain full coverage; missing Git
evidence fails the selector. Classification runs from the immutable trusted base
before candidate checkout and selection on the same read-only runner; there is
no separate prerequisite runner assignment. A successful trusted-base scope decision
for a deployment-only PR omits only the 48 explicitly inventoried smoke jobs; the
separate event-gated dependency-review smoke retains its scope condition. The other
31 selectable jobs and all independent shared guards remain available. Missing or
malformed scope output fails selection; unproven classification keeps full coverage.
Renames retain both old and new owners. Main keeps full
coverage, and existing merge-group/release exclusions, credential-specific and
independently admitted offline caller jobs
remain unchanged. Eight interface-only callers whose callee jobs intentionally
skip, plus two PR-only callees with event, actor or fork exclusions, retain their
original admission outside the execution selection. Their failures still reach
the global reducer; selected execution jobs must succeed. The credential graph, test-wiring, shell,
documentation and manifest
guards never depend on selection. The workspace-free required reducer requires a
successful selector and every selected job's success; an unexpectedly skipped test
cannot make CI green. Keep `test-ci-selection.sh`, its inventory and required-reducer
negative controls passing. Historical coverage and burst latency measurements remain
separate evidence in #475.

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

