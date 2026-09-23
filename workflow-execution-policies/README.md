# Workflow execution policies

GitHub can restrict which actors and events may start each Actions workflow ("workflow execution
protections"). This folder holds the policies we intend to use across the organization, one file per
policy, reviewed through pull requests.

**How they reach the organization.** The rest of our GitHub configuration goes through Crossplane
and the GitHub Terraform provider, which has no resource for these policies: its latest release
(6.13.0) predates the feature's general availability on 2026-09-17. So
[`apply-workflow-execution-policies.yaml`](../.github/workflows/apply-workflow-execution-policies.yaml)
applies them instead. When a change here lands on `main`, every day, and on demand, it runs
[`scripts/apply-workflow-execution-policies.sh`](../scripts/apply-workflow-execution-policies.sh):
the organization's policies are made to match these files, matched by name, and each one is read
back and must match. A policy changed by hand is set back on the next run. Nothing is deleted: a live
policy that no file names is reported and left alone. The token comes from the organization-wide App
credential (`APP_CLIENT_ID` and `APP_PRIVATE_KEY`) and carries organization administration only.
Moving the policies into `deploy/` once the provider supports them is tracked in
[#226](https://github.com/devantler-tech/.github/issues/226). Roadmap:
[#202](https://github.com/devantler-tech/.github/issues/202).

## Format

Each `*.json` file is the request body of
[`POST /orgs/{org}/actions/policies`](https://docs.github.com/en/rest/actions/policies), so it can
be sent as-is. The one addition is an optional `exception` object, which is our review record and
must be removed before sending: a policy may allow `pull_request_target` or `workflow_run` only when
`exception` lists the `workflow_paths` it covers and a `threat_model` saying why they are safe, and
the policy itself targets only those paths.

Moving a policy to `active` is the maintainer's call. See [Testing a policy before it
blocks](#testing-a-policy-before-it-blocks) for how that step is made safely.

Actors are numeric IDs with their API type (`User`, `Bot`, `App`, …), never logins, because a
login can be renamed and reused.

## Policies

| File | What it does |
|---|---|
| `allow-observed-events.json` | Every workflow in every repository may start only on the eight events our default-branch workflows use today. This blocks `pull_request_target`, `workflow_run` and `repository_dispatch`, none of which any workflow needs. |
| `restrict-deploy-starters-<repository>.json` | In each repository with manually startable deploy or publish workflows, only the portfolio's own identities may start those workflow files. One file per repository, because a file name like `ci.yaml` means a different workflow in each repository. |

## Deploy and publish starters

Targets: every default-branch workflow that accepts manual entry **and** deploys or publishes
(`scripts/workflow-execution-inventory.sh --org devantler-tech`, 2026-09-22: 32 workflows, 28 targeted).
Allowed actors come from `scripts/workflow-execution-actors.sh --org devantler-tech --since 2026-08-23`:

| Actor | ID / type | Why |
|---|---|---|
| devantler | 26203420 / User | Starts manual runs, and pushes when merging directly. |
| github-merge-queue[bot] | 118344674 / Bot | Pushes from the merge queue. A scheduled run is attributed to whoever last changed its schedule, which in queue-gated repositories is the merge queue. |
| botantler-1[bot] | 185060876 / Bot | Pushes that land release and sync pull requests. |
| github-actions[bot] | 41898282 / Bot | Platform only: one platform workflow starts another. |
| dependabot[bot] | 49699333 / Bot | **Not allowed.** Seen only on workflows excluded below. GitHub exempts its own built-in Dependabot runs. |

Excluded on purpose, because they also run on `pull_request`, where the actor is the pull request
's author and an actor rule would block contributors' CI: ksail `ci.yaml` and platform
`publish-coroot-node-agent-hotfix.yaml`, `publish-kubescape-node-agent-hotfix.yaml` and
`publish-kubescape-storage-hotfix.yaml`. The actor evidence could not verify three workflows
(platform and ksail `ci.yaml`, actions `enable-auto-merge.yaml`); none is targeted.

Workflow paths are written repository-relative (`.github/workflows/<file>`). The REST reference
does not say whether that is the expected form, so each policy targets a single repository. Every
file is `disabled` until the apply workflow's read-back confirms the form: if GitHub stores a
different one, the run fails with `MISMATCH` and prints both.

## Testing a policy before it blocks

GitHub's `evaluate` mode reports what a policy would block without blocking it. GitHub's
[workflow execution protections](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/actions-policies/workflow-execution-protections) page labels that option
"(GitHub Enterprise Cloud only)". This organization is on the Team plan
(`gh api orgs/devantler-tech --jq .plan.name` returns `team`), so it cannot use `evaluate`, and a
policy is never observed in a non-blocking mode. A policy can only be `active` or `disabled`
here, so every checked-in file says `disabled`, and the check rejects any other value.

Without `evaluate`, a policy is tested in two steps:

1. **Compare the policy with the evidence (simulation).** Run
   `scripts/workflow-execution-actors.sh --org devantler-tech --since <YYYY-MM-DD>`, with the date
   30 days before the run, and confirm that every actor that started each targeted workflow in that window is allowed. Run
   `scripts/workflow-execution-inventory.sh --org devantler-tech` and confirm that every event the
   current default-branch workflows accept is allowed. The inventory reads only each repository's
   default branch, while the event policy applies to workflows on every branch and tag. So also
   confirm that every value in the actors report's `event` column is allowed: that report covers
   runs from any ref in the window. A workflow that exists only on another ref and did not run in
   the window appears in neither, so the `allow-observed-events.json` trial below is the only check
   for it. Both scripts must exit 0 with no `UNKNOWN` row, and every `NO-RUNS` row must
   be reviewed by hand: it only means nothing ran in the window, not that no actor is needed. With
   incomplete evidence, do not activate. This is our own comparison, not GitHub telemetry, and it
   does not prove the policy is enforced.
2. **Activate one policy on one low-risk repository first.** Start with a template repository's
   `restrict-deploy-starters-*` policy. Activation is a pull request that sets that file's
   `enforcement` to `active`, and the apply workflow turns the policy on once it lands. The check
   rejects `active`, so the first activation pull request also changes the check to allow it, and
   it needs the maintainer's approval. Keep the policy `active` for a week and check that the
   repository's releases and syncs still run. Rollback is reverting that pull request. Record the
   outcome on [#202](https://github.com/devantler-tech/.github/issues/202) before activating the
   next policy. The organization-wide `allow-observed-events.json` goes last.

GitHub documents that its built-in processes (code scanning default setup, Dependabot updates) are
exempt from actor restrictions, so the `restrict-deploy-starters-*` trial covers that case. It does
not document an exemption from event restrictions. Confirm that those runs still start while
`allow-observed-events.json` is active, during its own trial, before relying on it.

## Checks

`bash tests/workflow-execution-policies.sh` runs in CI. It rejects an unknown top-level key or condition, a policy that names workflow files without targeting exactly one repository, an unknown
rule, event or actor type, a non-integer actor ID, any enforcement other than `disabled`, a privileged trigger
without an exception, and malformed repository or workflow targeting.

`bash tests/apply-workflow-execution-policies.sh` also runs in CI. It drives the apply script
against an offline stand-in for GitHub's API and fails when the script writes anything while the
files are invalid or the live list is incomplete, sends the review-only `exception`, counts GitHub's
own fields or list order as drift, misses a policy on a later page, changes a policy it does not
manage, or accepts a read-back that differs from what it sent.

The event list came from `scripts/workflow-execution-inventory.sh --org devantler-tech` on
2026-09-21 (144 workflows across the active repositories). Re-run it when adding a workflow that
needs a new event, and update the policy in the same pull request.
