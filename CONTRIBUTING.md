# Contributing to the shared automation repository

Useful first contributions include clarifying an action example, correcting a workflow input
description, or adding a focused regression fixture. Discuss substantial changes in an
[issue](https://github.com/devantler-tech/.github/issues) first: changes here can affect every
consumer repository. For sensitive vulnerabilities, use [private reporting](.github/SECURITY.md),
not a public issue or PR.

## Make a first documentation change

You need Git, Bash, `jq`, `awk`, and the Go implementation of
[Mike Farah's `yq` v4](https://github.com/mikefarah/yq). The unrelated Python `yq` package is not a
substitute. Check `yq --version` before starting. These documentation checks need no cluster,
organization credentials, publishing access or application runtime.

Fork `devantler-tech/.github` on GitHub. Replace `YOUR-LOGIN` with your login:

```sh
git clone https://github.com/YOUR-LOGIN/.github.git
cd .github
git switch -c docs/first-contribution
```

From the repository root, make a small wording correction in `README.md`. If it describes a
workflow input or secret, check the actual declaration under `.github/workflows/`; its table must
remain in that workflow's own level-three README section. Then run:

```sh
bash .scripts/check-workflow-readme.sh
bash .github/tests/test-workflow-readme-parity.sh
git diff --check
```

All three commands should exit successfully. The first reports documented inputs/secrets across
reusable workflows; the second exercises the checker against temporary positive and negative
fixtures. They inspect local files and clean up their temporary fixtures. They do not execute the
advertised workflows, deploy manifests, contact the organization, or prove credentials work.

## Choose the right source and checks

| Change | Guidance |
| --- | --- |
| Composite action or reusable workflow | [Catalogue conventions](actions/CONTRIBUTING.md), including backward-compatible interfaces, pinned references, and required CI test wiring |
| Declarative organization configuration | [Authoring and local render checks](deploy/README.md#authoring-changes); keep Observe-first adoption and the no-Delete boundary |
| Organization community defaults | Files under `.github/` can be inherited by other repositories. Keep them repository-neutral, and check existing target-specific policies |
| Generated workflow projection | Change its production workflow or named generator and regenerate; never hand-edit the projection |

The catalogue was imported once; it is maintained here now. Do not rerun
`scripts/import-actions-catalogue.sh` as a documentation updater: it replaces the historical
snapshot's files. The frozen `devantler-tech/actions` repository is not the source for new changes.

The [CI workflow](.github/workflows/ci.yaml) runs broader catalogue, security, interface, credential
boundary and declarative-governance checks, then aggregates required results. The small local path
above is a documentation checkpoint, not a replacement for that matrix. Read the relevant
[repository contract](AGENTS.md) before changing behavior. Publishing, live audits and reconciling
managed organization settings are separate maintainer operations, not onboarding steps.

Before **every PR**, including a documentation-only PR, also run all fourteen commands in the
[Maintenance baseline](AGENTS.md#maintenance). Install `kubectl` for its local Kustomize render
and Perl for the repository-drift regression fixtures. The regression tests use offline fixtures,
not your organization's live settings. Every command
must succeed. The documentation checkpoint helps you start, but does not waive this baseline or
the broader required CI.

Changes under `deploy/`, including its documentation, must pass the release-driving subject
guard. Use a `fix`, `feat`, `perf`, `revert`, or breaking Conventional Commit subject appropriate
to the outcome. With one commit, GitHub uses that commit's subject for the squash; with multiple
commits, it uses the PR title. Retitling a one-commit PR alone will not repair this gate. The
[release-contract validator](scripts/validate-release-contract.sh) enforces this so a deployment
artifact change cannot merge without a corresponding release. The first README-only example above
does not change `deploy/`.

## Submit your change

Review the diff and stage only your changed paths. Configure commit signing and use a Conventional
Commit subject, for example:

```sh
git add README.md
git commit -S -m "docs: clarify a workflow input"
git push -u origin docs/first-contribution
```

Open a **draft** PR from your fork's branch to `devantler-tech/.github:main`. Use the
[PR template](.github/PULL_REQUEST_TEMPLATE.md), keep Why/What focused on the reader problem and
outcome, and link the issue for substantial work. Put detailed validation evidence in a PR comment
or check summary, not those sections. Disclose AI assistance when used.
Respond to findings; required CI and substantive review of the exact current head must pass before
merge. Follow the [code of conduct](.github/CODE_OF_CONDUCT.md) and preserve the
[Apache-2.0 license](LICENSE) and third-party attribution.
