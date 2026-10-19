# Check CI Run Budget

Reject a completed CI workflow that took 15 minutes or longer, including runner
waits, setup, dependent jobs and teardown. The check reads native GitHub metadata;
it does not execute the inspected revision or download its logs or artifacts.

This is a **single-workflow** check, not a whole-PR budget gate. Independent
required workflows must also be assessed. It is disabled unless explicitly enabled.

## Inputs

| Name | Description | Required | Default |
|---|---|---|---|
| `enabled` | Enable metadata reads and validation | No | `false` |
| `run-id` | Completed run in the calling repository | When enabled | — |
| `run-attempt` | Expected current attempt | When enabled | — |
| `head-sha` | Full lowercase source commit SHA | When enabled | — |
| `workflow-path` | Expected path such as `.github/workflows/ci.yaml` | When enabled | — |
| `event` | `pull_request` or `merge_group` | When enabled | — |
| `github-token` | Token with `actions: read` | No | Calling job's token |

The caller needs GitHub CLI and a Bash-capable Linux or macOS runner. The action
sets up the Go version declared by its inspector module. Keep job permissions
read-only; no App or write permission is needed.

## Outputs

| Name | Description |
|---|---|
| `validated` | `true` only after complete successful evidence below 900 seconds |
| `receipt` | JSON result with exact identity, original creation, actual completion and elapsed seconds |

Disabled and failed calls expose neither output. Failure logs contain a sanitized
JSON receipt: `over_budget` means optimize or redesign the workflow;
`ci_failed` means the native workflow did not succeed; `unknown` means the
evidence cannot support validation.

## Usage

Inspect an already completed run; do not point this action at its own running
workflow. Resolve the expected identity from a trusted observation, not a PR comment.

```yaml
permissions:
  actions: read
steps:
  - uses: devantler-tech/.github/actions/check-ci-run-budget@<full-commit-sha> # vX.Y.Z
    with:
      enabled: "true"
      run-id: "123456789"
      run-attempt: "1"
      head-sha: "<full-subject-commit-sha>"
      workflow-path: .github/workflows/ci.yaml
      event: pull_request
```

Replace the action version and subject placeholders before running. The deadline
is fixed: strictly less than 900 seconds. A rerun keeps the original workflow
creation time rather than receiving another 15 minutes. Mutable workflow update
timestamps never determine completion.

See the [measurement contract](../../docs/ci-feedback-budget.md) for scope and
failure behavior, and [portfolio rollout](https://github.com/devantler-tech/.github/issues/654)
for whole-PR aggregation and required enforcement.
