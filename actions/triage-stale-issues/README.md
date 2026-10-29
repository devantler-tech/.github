# Triage Stale Issues

Use the official `actions/stale` action with the portfolio's shared 90-day reminder
and 30-day closure policy. No repository checkout or App credential is required.

## Policy

Eligible issues receive `stale` after 90 days without activity. After another 30
inactive days they close as **not planned**, with a comment explaining how to reopen.
New activity removes `stale` and resets the timer. A new reminder never immediately
closes an old issue. Pull requests and branches are unchanged.

`blocked`, `keep-open`, `maintainer-ask` and `maintainer-ask-urgent` exempt an issue.
The pinned release supports a positive native issue-type list: Chore, Bug, Feature,
Kata, Performance, Refactor, Docs and Spike are eligible; Epic, Security, untyped and
unknown types require explicit triage instead of automatic closure. Assigned issues
and milestones follow the same inactivity clock unless explicitly exempted.

Declare `stale` and `keep-open` through the Git-owned label configuration before
activation. The shared action refuses live triage until both exact label
definitions are readable. Do not create their definitions imperatively. Apply `keep-open` to
deliberately deferred external-availability tracking such as
[#805](https://github.com/devantler-tech/.github/issues/805) before rollout.

Renovate and Dependabot-owned issues retain their own lifecycle. Before a live
pass, the action reads the complete repository issue census and refuses to run
if an unexempted automation-owned issue could enter triage. It does not edit bot
issues to manufacture an exemption. Failed, incomplete or ambiguous reads also
refuse the pass. A one-day margin protects the boundary while the action runs.

Each run budgets 100 upstream issue-processing operations and processes oldest updates first. The
upstream cache resumes unfinished scans, so large repositories may require several
daily runs. `actions: write` permits replacing that progress cache; `issues: write`
permits labels, reminders and closure. No contents or pull-request write permission
is needed. A dry-run uses only issues/actions read and never persists its cursor.

The temporary rollout gate defaults on after validation. This changes omitted-input
behavior from no-op to live triage when upgrading from the default-off interface.
Pass `enabled: "false"` explicitly to preserve opt-out behavior during this bridge
release. The permanent `dry-run` preview option is unchanged. Removal is tracked in
[#808](https://github.com/devantler-tech/.github/issues/808).

## Inputs

| Name | Description | Required | Default |
| --- | --- | --- | --- |
| `enabled` | Temporary rollout gate; explicit false runs no triage | No | `true` |
| `dry-run` | Preview proposed actions without issue or cursor changes | No | `false` |
| `github-token` | Repository-scoped token; read-only for preview, issues/actions write for live triage | No | `github.token` |

There are no action outputs. Read the upstream statistics and job logs for the
processed batch; a preview is not evidence of completed mutations.

## Usage

Prefer the [reusable workflow](../../README.md#workflow-triage-stale-issues) for a
scheduled job. If composing an existing job, use this action directly:

```yaml
permissions:
  issues: write
  actions: write
steps:
  - uses: devantler-tech/.github/actions/triage-stale-issues@<full-commit-sha> # vX.Y.Z
```

Replace the example pin with the reviewed published release's full commit SHA.
Shared-source publication, managed-label convergence and actual consumer execution
are separate rollout gates tracked in
[#806](https://github.com/devantler-tech/.github/issues/806).
