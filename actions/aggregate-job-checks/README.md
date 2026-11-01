# Aggregate Job Checks

A GitHub composite action that aggregates job results into one stable required check. It fails if a supplied job failed, was cancelled, or was abandoned. An optional startup check also catches workflows that failed before creating any jobs.

## Why?

GitHub branch protection rules require a specific check to pass. When using matrix builds or conditional jobs, the check names can vary (e.g., `build (ubuntu, go-1.21)`, `build (macos, go-1.22)`). This action provides a single, stable check name that reports the aggregate status of all jobs.

## Usage

```yaml
jobs:
  build:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: echo "Building..."

  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo "Testing..."

  ci-required-checks:
    name: CI - Required Checks
    runs-on: ubuntu-latest
    needs: [build, test]
    if: ${{ always() }}
    steps:
      - uses: devantler-tech/.github/actions/aggregate-job-checks@<full-commit-sha> # vX.Y.Z
        with:
          job-results: "${{ needs.build.result }} ${{ needs.test.result }}"
```

## Inputs

| Input | Description | Required | Default |
| --- | --- | --- | --- |
| `job-results` | Space-separated list of job results to check | Yes | — |
| `check-name` | Display name used in success/failure messages | No | `CI - Required Checks` |
| `check-workflow-startup` | Inspect current-head workflow startup evidence | No | `false` |
| `github-token` | Token with Actions read access to the calling repository, used only when startup checking is enabled | No | `github.token` |

## Check workflow startup failures

A workflow can fail before GitHub creates any jobs or check runs. Its failure is then absent from the supplied job results. Enable the startup check to inspect workflow-run metadata as well:

```yaml
  ci-required-checks:
    name: CI - Required Checks
    runs-on: ubuntu-latest
    needs: [build, test]
    if: ${{ always() }}
    permissions:
      actions: read
    steps:
      - uses: devantler-tech/.github/actions/aggregate-job-checks@<full-commit-sha> # vX.Y.Z
        with:
          job-results: "${{ needs.build.result }} ${{ needs.test.result }}"
          check-workflow-startup: "true"
```

Use the opt-in for `pull_request`, `push` and `merge_group` runs on Linux or macOS. The runner needs Bash, GitHub CLI and `jq`; the action sets up its Go inspector toolchain. Keep any other permissions your existing job needs. No checkout of the caller's repository or GitHub App credential is needed. Disabled use performs no inspector setup or metadata reads.

The inspector reads only GitHub API metadata. It binds observations to the native repository, run, attempt and head, excludes its own unfinished run, and checks complete workflow inventories twice. It rejects startup failures and failed attempts with no jobs. Ordinary job failures remain the responsibility of their existing checks.

A later success clears older failures only for the same workflow, event, branch and known PR associations. Manual runs, skipped runs and pending replacements do not establish recovery. When GitHub omits a failed PR run's association, a different run cannot prove recovery; rerun that failed native run after fixing the cause, or validate a new corrected commit.

This is a startup snapshot, not a monitor of later events or a 15-minute feedback-budget check. Reevaluate the aggregate after a later workflow outcome. Missing permissions, incomplete or changed metadata, and the API's 1,000-result search boundary fail as unknown instead of producing a clear receipt.

## Outputs

| Output | Description |
| --- | --- |
| `startup-clear` | `true` only after a complete clear startup snapshot; unset when disabled or unsuccessful |
| `startup-receipt` | Sanitized JSON with `scope: head_workflow_startup_snapshot`, a reason, and `state: clear`, `blocked` or `unknown` |

A blocked or unknown verdict fails the action and emits no success output. For a startup failure, correct the workflow and rerun it. For unknown metadata, check API availability, the job's Actions read permission and the reported reason, then rerun the aggregate. A clear startup receipt does not override any other required check.

## Job Result Values

| Result      | Description                         | Treated as |
| ----------- | ----------------------------------- | ---------- |
| `success`   | Job completed successfully          | ✅ Pass     |
| `skipped`   | Job was skipped (condition not met) | ✅ Pass     |
| `failure`   | Job failed                          | ❌ Fail     |
| `cancelled` | Job was cancelled                   | ❌ Fail     |
| `abandoned` | GitHub gave up on the job           | ❌ Fail     |

GitHub documents only `success`, `failure`, `cancelled` and `skipped` for `needs.<job>.result`, but it also reports `abandoned` when it gives up on a job — typically a runner or infrastructure transient. The check fails with a message naming the abandoned job as a GitHub-side outcome and pointing at a re-run. Any other value fails as malformed `job-results` input, so a broken calling workflow stays distinguishable from a GitHub-side outcome.

## Custom Check Name

```yaml
  ci-ksail:
    name: CI - KSail
    runs-on: ubuntu-latest
    needs: [build, lint, test]
    if: ${{ always() }}
    steps:
      - uses: devantler-tech/.github/actions/aggregate-job-checks@<full-commit-sha> # vX.Y.Z
        with:
          job-results: >-
            ${{ needs.build.result }}
            ${{ needs.lint.result }}
            ${{ needs.test.result }}
          check-name: CI - KSail
```
