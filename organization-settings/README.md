# Detect organization-settings drift

The audit checks the four settings in `expected.json`: commit signoff, default repository access,
repository creation by members, and required two-factor authentication. It reads GitHub once and
compares every declared value. Exit 0 means all four match, exit 1 means measured drift, and exit 2
means the policy or observation is invalid or incomplete. Output contains only the verdict and
aggregate count; failed reads never produce a clean result.

Run `bash scripts/check-organization-settings.sh` with a credential that can read these organization
settings, or explicitly enable **Organization settings audit** on reviewed `main`. Its input defaults
to false; the disabled job mints no token. The enabled job requests organization Administration read,
revokes its short-lived App token in the post step, and cannot change organization settings.

This policy is an audit document, not a Crossplane resource. Provider-based adoption remains in
[#85](https://github.com/devantler-tech/.github/issues/85). Routine scheduling, issue-on-drift reporting
and retirement of the manual opt-in remain in [#404](https://github.com/devantler-tech/.github/issues/404).
