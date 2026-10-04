# Routine governance audits

This workflow checks complete repository coverage and effective admin-team permissions from
reviewed main. It reads GitHub state and never changes a repository setting or team grant.
Private coverage diagnostics stay in a temporary file; public reports contain only the outcome.

The daily schedule and input-free manual dispatch run the same complete auditors and
reporter. Admission requires the canonical workflow on reviewed main; an unexpected
event, incomplete context or failed output reports UNKNOWN and cannot clear a gap.

The audit job requests Metadata(read) and Administration(read) over the complete installation.
Its token is revoked by the App action's post handler. The separate reporter has only issue-writing
authority, receives no App key, and keeps one tracking issue open after a failed or incomplete
audit. It closes that issue only after both complete audits succeed.

Routine admission has no experimental switches. The natural daily run completed
both full checks and the success reporter; its implementation and observation are
tracked in [#395](https://github.com/devantler-tech/.github/issues/395).
Legacy maintenance retirement remains [#84](https://github.com/devantler-tech/.github/issues/84).

Organization-settings adoption and observer scheduling remain separate in
[#85](https://github.com/devantler-tech/.github/issues/85) and
[#404](https://github.com/devantler-tech/.github/issues/404).
