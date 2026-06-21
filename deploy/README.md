# `deploy/` — declarative GitHub state

This directory is the source of truth for the devantler-tech org's GitHub
configuration, expressed as [Crossplane](https://crossplane.io) managed
resources (via
[provider-upjet-github](https://github.com/crossplane-contrib/provider-upjet-github)).

On every `v*` tag, [`cd.yaml`](../.github/workflows/cd.yaml) publishes this
directory as a **cosign-signed OCI artifact** to
`ghcr.io/devantler-tech/github-config/manifests`. The
[platform](https://github.com/devantler-tech/platform) cluster onboards it as
the **`github-config` tenant**: it verifies the signature, then Flux + Crossplane
reconcile the live GitHub org to match these manifests — including reverting
out-of-band changes made in the GitHub UI.

- `repositories/` — one `Repository` per managed repo.
- `teams/` — the `maintainers` team, its membership, and team → repo access.
- `labels/` — one `IssueLabels` per managed repo. The canonical org label
  taxonomy lives once in `labels/kustomization.yaml` (a shared patch appended to
  every repo); each `<repo>.yaml` adds only that repo's Dependabot/Renovate
  ecosystem extras. Authoritative — out-of-band label drift is reverted. This is
  the Crossplane replacement for the old EndBug/label-sync workflow.

See the platform repo's
[`docs/github-management.md`](https://github.com/devantler-tech/platform/blob/main/docs/github-management.md)
for the architecture, the GitHub App credential setup, and the **Observe-first**
adoption flow for bringing an existing repository under management without any
risk of recreating or deleting it.
