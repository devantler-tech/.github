# CI feedback budget

The single-run check accepts one completed workflow run and an expected repository,
head commit, workflow path, event and attempt. It reads GitHub metadata only.
It does not certify an entire pull request: independent required workflows and
current-head reporting are separate concerns tracked in issue #654.

The clock starts at the original workflow creation and ends at the latest actual
job completion. Runner waits, setup, job dependencies and teardown count. Workflow
update times do not determine completion. A rerun retains its original creation
time. A duration strictly below 900 seconds passes; 900 seconds or more fails.

Every page must advertise the same complete job count. Job identities are unique
and bound to the expected run and head. Successful reused jobs from earlier
attempts may appear in GitHub's latest-job view, but no job may belong to a future
attempt. All jobs must have terminal completion timestamps and report success or
an intentional native skip; at least one successful job must exist. Successful
jobs require chronological execution times. Native skips have no execution
interval: their completion counts, but a synthetic start stamped after completion
does not invalidate it. Failed commands, malformed responses,
partial pages, impossible timestamps and a changed final run identity produce
unknown evidence, never a pass.

The inspector uses bounded, explicit GET requests through GitHub CLI to
github.com. Candidate source, logs and artifacts are never fetched or executed.
API errors expose no response body or credential diagnostics. Receipts identify
their single-workflow scope; disabled and unsuccessful action calls publish no
validation output.

The catalogue action is opt-in and default-off. Whole-PR aggregation, race-safe
current-head reporting, managed required enforcement, consumer adoption and
rollout-switch retirement remain distinct delivery gates under issue #654.
