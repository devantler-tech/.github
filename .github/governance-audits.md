# Routine governance audits

This workflow checks complete repository coverage and effective admin-team permissions from
reviewed main. It reads GitHub state and never changes a repository setting or team grant.
Private coverage diagnostics stay in a temporary file; public reports contain only the outcome.

The daily schedule starts disabled in `governance-audits.json`. An explicit manual opt-in runs the
same complete auditors and reporter. A false manual input skips every App-token and report step.
Invalid policy or incomplete admission reports failure rather than silently clearing a gap.

The audit job requests Metadata(read) and Administration(read) over the complete installation.
Its token is revoked by the App action's post handler. The separate reporter has only issue-writing
authority, receives no App key, and keeps one tracking issue open after a failed or incomplete
audit. It closes that issue only after both complete audits succeed.

Initial delivery is tracked in [#406](https://github.com/devantler-tech/.github/issues/406).
Activate scheduling through a reviewed change only after the actual main manual control and
complete audit pass. Routine observation and retirement of both the manual opt-in and scheduled
rollout flag remain in [#395](https://github.com/devantler-tech/.github/issues/395). Legacy maintenance
retirement remains [#84](https://github.com/devantler-tech/.github/issues/84).

Organization-settings adoption and observer scheduling remain separate in
[#85](https://github.com/devantler-tech/.github/issues/85) and
[#404](https://github.com/devantler-tech/.github/issues/404).
