# Workflow execution policies

GitHub can restrict which actors and events may start each Actions workflow ("workflow execution
protections"). This folder holds the policies we intend to use across the organization, one file per
policy, reviewed through pull requests.

**Nothing here is applied yet.** Our GitHub configuration reaches the live organization through
Crossplane and the GitHub Terraform provider, and that provider has no resource for these policies:
its latest release (6.13.0) predates the feature's general availability on 2026-09-17. Applying them
by hand would leave them outside the reconciler and outside the drift check. The files stay here as
reviewed desired state until a GitOps path exists, or until the maintainer approves an interim
apply. Roadmap: [#202](https://github.com/devantler-tech/.github/issues/202).

## Format

Each `*.json` file is the request body of
[`POST /orgs/{org}/actions/policies`](https://docs.github.com/en/rest/actions/policies), so it can
be sent as-is. The one addition is an optional `exception` object, which is our review record and
must be removed before sending: a policy may allow `pull_request_target` or `workflow_run` only when
`exception` lists the `workflow_paths` it covers and a `threat_model` saying why they are safe, and
the policy itself targets only those paths.

Every policy starts in `evaluate` mode, so GitHub reports what it would block without blocking it.
Moving a policy to `active` is the maintainer's call.
Evaluate mode is also where to confirm that GitHub-managed runs (code scanning default setup,
Dependabot updates) are exempt from the event list, as GitHub documents for built-in processes.

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
does not say whether that is the expected form, so each policy targets a single repository, and the
form must be confirmed before any apply.

⚠️ GitHub documents evaluate mode as GitHub Enterprise Cloud only, and this organization is on the
Team plan. How to test these policies safely is tracked in
[#213](https://github.com/devantler-tech/.github/issues/213).

## Checks

`bash tests/workflow-execution-policies.sh` runs in CI. It rejects an unknown top-level key or condition, a policy that names workflow files without targeting exactly one repository, an unknown enforcement mode,
rule, event or actor type, a non-integer actor ID, `active` enforcement, a privileged trigger
without an exception, and malformed repository or workflow targeting.

The event list came from `scripts/workflow-execution-inventory.sh --org devantler-tech` on
2026-09-21 (144 workflows across the active repositories). Re-run it when adding a workflow that
needs a new event, and update the policy in the same pull request.
