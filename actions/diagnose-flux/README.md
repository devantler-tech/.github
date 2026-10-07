# Diagnose Flux on failure

Dump Flux reconcile state, controller logs, and failing/CrashLooping pod logs to
debug a stuck Flux deploy in CI/CD. When a system-test or prod deploy fails, the
useful signal is spread across the Flux CRs (`Kustomization` / `HelmRelease` /
`OCIRepository` status), the `flux-system` controller logs, and the logs of
whatever pod is actually crash-looping — and a `CrashLoopBackOff` pod stays in
`phase=Running` with `waiting.reason=CrashLoopBackOff`, so naively filtering on
phase misses it. This action gathers all of that into grouped log sections in
one step.

Collection has a 120-second budget by default, with at most five seconds per
command. Current failing Pods come before healthy active Job Pods (up to 20
combined, newest first within each group), followed by a
snapshot from one Pod of each Flux controller Deployment and previous logs for
the selected Pods. Failed Job descriptions (up to 10), resource state,
warning events and the five newest completed Job Pod logs provide supplementary
evidence. At most 48 `kubectl logs` commands run, even with thousands of retained
Jobs. Each command's process group is stopped on timeout, and its command and
watchdog are joined before collection continues or returns.

Unavailable reads, invalid inventories, expired budgets and omitted evidence are
reported explicitly. A completed collection does not imply a healthy cluster.

It is **best-effort** (`set +e`): it never fails the calling step itself, so a
transient `kubectl`/`jq` hiccup can't mask the original failure. Gate it with
`if: failure()` on the caller so it only runs when the deploy/test step failed.

> **Assumes `kubectl` is already configured** for the target cluster (the calling
> job has set up the kubeconfig/context) and that `jq` is available — both are
> present on the GitHub-hosted `ubuntu-latest` runner image.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `kustomizations` | Space-separated Flux Kustomization names (in `flux-system`) to `describe` on failure | ❌ | `infrastructure-controllers infrastructure apps` |
| `request-timeout-seconds` | Maximum time for each command, from 1 to 30 seconds | ❌ | `5` |
| `collection-timeout-seconds` | Overall collection budget, from 1 to 120 seconds | ❌ | `120` |

Only the first 10 Kustomization names are described. Invalid bounds report
unavailable diagnostics and perform no cluster reads; the caller's original
failure is preserved.

## Usage

### Diagnose a failed Flux deploy

```yaml
steps:
  - name: 🚀 Deploy
    run: ksail up # …or whatever drives the Flux reconcile

  - name: 🩺 Diagnose Flux on failure
    if: failure()
    uses: devantler-tech/.github/actions/diagnose-flux@<full-commit-sha> # vX.Y.Z
```

### Describe a different set of Kustomizations

```yaml
steps:
  - name: 🩺 Diagnose Flux on failure
    if: failure()
    uses: devantler-tech/.github/actions/diagnose-flux@<full-commit-sha> # vX.Y.Z
    with:
      kustomizations: infrastructure apps tenants
```
