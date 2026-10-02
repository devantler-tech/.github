# Contributing

## Naming Conventions

### Action Directories

Use the `<active-verb>-<purpose>` pattern:

- ✅ `enable-auto-merge-on-pr`, `setup-go-toolchain`, `login-to-ghcr`
- ❌ `auto-merge-action`, `go-setup`, `ghcr`

### Inputs and Outputs

Use **kebab-case** for all action inputs, including secret-backed ones. Workflow inputs can keep their own conventions:

- ✅ `app-id`, `go-version`, `github-token`, `app-private-key`
- ❌ `app_id`, `goVersion`, `GITHUB_TOKEN`, `APP_PRIVATE_KEY`

## Action Structure

Each action directory must contain:

- `action.yaml` — Action metadata with `name`, `description`, `author: devantler-tech`, inputs, and steps
- `README.md` — Documentation following the [template](#readme-template)

### README Template

```markdown
# <Action Name>

<One-line description>

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|

## Outputs

| Name | Description |
|------|-------------|

## Usage

### <Scenario>

\`\`\`yaml
steps:
  - uses: devantler-tech/.github/actions/<action-name>@<full-commit-sha> # vX.Y.Z
    with:
      ...
\`\`\`
```

## Action Type

Prefer **composite actions** over JavaScript or Docker actions unless complexity demands otherwise.

## Distribution and Marketplace

The action suite is portfolio-first and publicly reusable by direct path, but it
is intentionally not published as a family of GitHub Marketplace listings in its
current multi-action repository layout. Marketplace publishing requires a root
`action.yml` or `action.yaml`; metadata in subdirectories is not automatically
listed. Do not add `branding:` to nested action metadata as a proxy for
publication.

If an action develops enough independent demand to justify its own repository,
extract it deliberately and give that single-action repository its own branding,
release lifecycle, and Marketplace listing.

## Testing

Every action has a `test-<action-name>` job in the consolidated
[`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml). The job calls the local
action with `uses: ./actions/<action-name>`, starts with SHA-pinned
`step-security/harden-runner` in audit mode, checks out with
`persist-credentials: false`, and verifies its real behavior with safe fixtures.
Reusable-workflow scenarios are jobs in that same file and call
`uses: ./.github/workflows/<workflow>.yaml` with non-destructive parameters.

Wire every new job into **both** `ci-required-checks.needs` and the trusted inline
summary step's `JOB_RESULTS` value using `${{ needs.<job-id>.result }}`. A job omitted
from either side is incomplete coverage. The summary runs with `always()` and
`permissions: {}` and executes no checked-out action; it is the sole exception
to harden-runner-first. Run the coverage and script-wiring checks from
[`AGENTS.md`](../AGENTS.md#test-jobs) before opening a PR.

Every `.github/tests/test-*.sh` entrypoint, regardless of executable bit, has an
unconditional dedicated invocation in a blocking CI job, anchored at the
repository root and included in both summary aggregations. Printed commands,
comments and helpers do not count as execution.

## Security

- Run [zizmor](https://github.com/zizmorcore/zizmor) to scan for GitHub Actions vulnerabilities
- Pin every remote action and reusable workflow to a full 40-character commit SHA,
  including `actions/*`, `github/*` and `devantler-tech/*`. Use
  `@<full-commit-sha> # vX.Y.Z` in documentation and replace both placeholders before
  running an example. Local `./` references resolve against the checked-out commit.
- **External action pin comment convention.** Annotate each third-party SHA pin so a
  reader can tell at a glance whether it tracks a tag or a branch:
  - Pinned to a release tag → `# v<version>` (e.g. `# v6.0.2`). This is the default;
    use it whenever the upstream publishes releases.
  - Pinned to a branch commit because the upstream publishes **no tags or releases**
    (main-tracked only) → `# <branch> (no upstream releases)` (e.g.
    `# main (no upstream releases)`). This keeps the comment honest — it names the
    branch and *why* there is no version, so a future re-pin to a newer branch
    commit is not mistaken for a floating branch ref.

## Reliability

A composite step that performs a **network pull** — a Homebrew tap/install, a
registry login, a tool/toolchain download — can fail a *required* CI check on a
transient registry/network flake (a GHCR 5xx, a DNS/TLS blip) rather than on a
real defect, blocking unrelated PRs across every consumer repo. Wrap such pulls
in the shared bounded-retry helper so infra noise can't masquerade as a failure:

```bash
retry() { bash "${GITHUB_ACTION_PATH}/../../.scripts/retry.sh" "$@"; }
retry brew install <formula>
```

`.scripts/retry.sh` retries with exponential backoff (tunable via
`RETRY_MAX_ATTEMPTS`, `RETRY_BASE_DELAY`, `RETRY_MAX_DELAY`) and exits non-zero
with the command's last status once attempts are exhausted, so a genuine failure
still reds the check. Only wrap the **network** commands — leave local operations
unwrapped. It is used by `setup-ksail-cli` (`brew tap` / `brew install`), by the
shared `.scripts/ensure-gh-skill.sh` (the `gh` release download), and by
`setup-agent-skills` / `update-agent-skills` (`gh skill install` / `gh skill
update` registry pulls) — covering every shell-based network pull in the suite as
part of the reliability pillar
([devantler-tech/actions#247](https://github.com/devantler-tech/actions/issues/247)).

## Commits

Use [semantic commits](https://www.conventionalcommits.org/):

- `feat:` — New action or feature
- `fix:` — Bug fix
- `docs:` — Documentation changes
- `chore:` — Maintenance tasks
- `ci:` — CI/CD changes
