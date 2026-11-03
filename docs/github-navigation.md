# Find applications and workflow results on GitHub

Use the [Devantler Tech repository list](https://github.com/orgs/devantler-tech/repositories)
or the pinned repositories on the [organization page](https://github.com/devantler-tech).
The repository that owns an application also owns its README, workflow results and operational
instructions. The [project board](https://github.com/orgs/devantler-tech/projects/5) shows the work
queue; each issue belongs in the repository where it can be addressed.

Organization members may initially see a separate member-only README. Select **View as: Public**
on the organization overview, or open the [public profile view](https://github.com/devantler-tech?view_as=public),
to see the public README and pins. This repository's [README](../README.md) also links here.

## View an application's evidence

1. Open the application's repository and read its README for access, installation and support.
2. Follow a CI badge to its workflow results, or select the repository's **Actions** tab.
3. Select the relevant workflow and run. Check its branch or tag, commit and conclusion before
   using it as evidence for a change.
4. Open an individual job to see its steps and logs. A run's summary also lists any retained
   artifacts. Opening these pages does not start a workflow.

For example, open [KSail's README](https://github.com/devantler-tech/ksail#readme), then its CI badge
or [CI - KSail workflow](https://github.com/devantler-tech/ksail/actions/workflows/ci.yaml).
Use the run list to choose the change you are investigating. A default-branch badge summarizes its
own workflow; it does not establish the result for a different pull request or prove deployment.

A missing badge or unavailable result means that signal is unverified. An old result applies to
the commit it names. Check the live run and the repository's instructions; report a missing or
misleading scorecard in the owning repository. [Scorecard work](https://github.com/devantler-tech/.github/issues/325)
tracks the shared evaluation and badge conventions.

Sign in with your existing GitHub account to navigate repositories you are allowed to see.
Their usual access controls apply to their README, issues, Actions and artifacts. Keep private
details within those repositories; this public guide does not list them.

## Inspect a manual-run form

You can inspect the form without submitting it:

1. Open the owning repository's **Actions** tab and select a workflow that supports manual runs.
   For an example, open [CI - KSail](https://github.com/devantler-tech/ksail/actions/workflows/ci.yaml).
2. Select **Run workflow** to open the form. GitHub requires repository write access to run it;
   the workflow must declare manual dispatch on its default branch, as explained in
   [GitHub's manual-run documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
   If the button is absent,
   check your access and the repository's workflow source.
3. Inspect **Use workflow from** and the input descriptions. For KSail CI, `run_system_tests`
   defaults to true and `run_local_recovery_trial` defaults to false. Confirm the current
   [workflow source](https://github.com/devantler-tech/ksail/blob/main/.github/workflows/ci.yaml)
   and the repository's instructions before choosing a ref or changing an input.
4. Close the form when you only need to understand the available operation.

To execute an operation, obtain its required authorization first. Manual runs can consume paid
resources, publish changes or affect production. Select the reviewed source/ref and inputs allowed
by that repository's procedure, then confirm **Run workflow**. Existing workflow permissions,
environment approvals and protected-main restrictions still apply. A visible button does not
grant permission to bypass them.

After submission, open the resulting run in that same workflow's run list. Confirm its selected
ref, commit, inputs and result, and use the run's URL when reporting the outcome on the related
issue or pull request. A manually dispatched run does not supply the required pull-request checks;
those must run and pass through the repository's normal protected workflow.
