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

## Checks

`bash tests/workflow-execution-policies.sh` runs in CI. It rejects an unknown top-level key or condition, an unknown enforcement mode,
rule, event or actor type, a non-integer actor ID, `active` enforcement, a privileged trigger
without an exception, and malformed repository or workflow targeting.

The event list came from `scripts/workflow-execution-inventory.sh --org devantler-tech` on
2026-09-21 (144 workflows across the active repositories). Re-run it when adding a workflow that
needs a new event, and update the policy in the same pull request.
