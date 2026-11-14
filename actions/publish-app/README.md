# Publish App

Publish a product release to GHCR from the product's own release workflow. The image and the
manifests artifact are keylessly signed **as the calling workflow on its release tag**, so the
signature names the product's own repository and tag:

```text
https://github.com/<owner>/<repo>/.github/workflows/<file>@refs/tags/vX.Y.Z
```

The platform can then trust each tenant's own repository on release tags instead of approving
every revision of a shared publisher.

## What it does

1. **Admits the release, before any registry contact.** It refuses unless:
   - the run's ref is `refs/tags/v<semver>` (SemVer 2.0.0; a pre-release is allowed, build
     metadata is dropped from the published version, and every number has at most 15 digits);
   - the calling workflow ref is this repository's own workflow file on that exact tag;
   - the checked-out commit is the tagged commit;
   - the tagged commit is an ancestor of the repository's default branch, which it fetches
     explicitly. When that cannot be established (fetch failure, no default branch), it refuses;
   - the inputs, `deploy-path` and `app-manifest` are valid (see below), and in `deployment` mode
     the app manifest holds exactly one container named `app-name`.
2. **Refuses an occupied release version** in the image and manifests repositories, from an
   authenticated, definitive registry read, before the first write.
3. **Builds or verifies the image.**
   - `deployment`: builds the repository root's `Dockerfile` with `docker/build-push-action` and
     pushes it to an unselectable `staging-<run>-<attempt>` tag.
   - `prebuilt-webapp`: verifies the caller's own public main-CI image signature and SLSA
     provenance (`ci.yaml@refs/heads/main`) and the CI run evidence, then pins that image into the
     WebApp. No image is built.
   - `manifests`: no image.
4. **Pins and stages.** In `deployment` mode it pins `image@digest` into the app manifest, then
   pushes the **whole** `deploy-path` as the manifests artifact to a staging tag.
5. **Signs and verifies by digest.** It signs the image and the artifact (with publication claims
   such as `devantler.source-sha`, `devantler.version` and `devantler.workflow-ref`), then runs
   `cosign verify` on both against the calling workflow's identity and the GitHub OIDC issuer.
6. **Exposes only verified releases.** After an image copy keeps the signed digest and the
   version is still unpublished, it tags the version, and `latest` for non-pre-releases. A failed
   verification exposes nothing.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `mode` | `deployment`, `prebuilt-webapp` or `manifests` | No | `deployment` |
| `app-name` | Container name in the Deployment, or the WebApp name, namespace and spec name in `prebuilt-webapp` mode. A DNS label. Must be empty in `manifests` mode | In `deployment` and `prebuilt-webapp` modes | `""` |
| `deploy-path` | Relative directory of plain names, published whole as the manifests artifact | No | `./deploy` |
| `app-manifest` | Path, relative to `deploy-path`, of the manifest holding the app. Empty means `deployment.yaml` (`webapp.yaml` in `prebuilt-webapp` mode). Must be empty in `manifests` mode | No | `""` |
| `oci-name` | `manifests` mode only: `<owner>/<name>` to publish under, in the caller's own namespace, for a repository whose name is not a valid OCI path (for example `.github`) | No | `""` |
| `prebuilt-image-digest` | `prebuilt-webapp` mode only: the original main-CI image `sha256:` digest | In `prebuilt-webapp` mode | `""` |
| `prebuilt-public-digest` | `prebuilt-webapp` mode only: the public artifact SHA-256 recorded by the image producer | In `prebuilt-webapp` mode | `""` |
| `prebuilt-ci-run-id` | `prebuilt-webapp` mode only: the successful public main-push CI run ID | In `prebuilt-webapp` mode | `""` |
| `prebuilt-ci-run-attempt` | `prebuilt-webapp` mode only: that run's successful, still current attempt | In `prebuilt-webapp` mode | `""` |
| `github-token` | Token for the default-branch fetch, registry reads and GHCR writes | No | `${{ github.token }}` |

`deploy-path` and `app-manifest` must be plain names joined by `/` (letters, digits, `.`, `_`
and `-`; no leading `/`, no empty, `.`, `..` or hidden component, no line break), and no
directory on the way, nor the manifest itself, may be a link. A refused value is not echoed.

## Outputs

| Name | Description |
|------|-------------|
| `version` | The published version: the tag without its `v` and build metadata |
| `image-digest` | The signed image digest (empty in `manifests` mode) |
| `manifests-digest` | The signed manifests artifact digest |

## Usage

The calling job must grant `contents: read`, `packages: write` and `id-token: write`, check out
the tagged commit at the workspace root, and call the action **directly in the product's release
workflow**. Called from inside a reusable workflow, the certificate would name that workflow
instead, and verification would refuse to expose the release. Serialize publishers of one
repository with a job concurrency group that never cancels.

### Build and publish an app

```yaml
on:
  push:
    tags:
      - "v*"

permissions: {}

jobs:
  publish:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    concurrency:
      group: publish-${{ github.repository }}
      cancel-in-progress: false
    permissions:
      contents: read # checkout and the default-branch fetch
      packages: write # push the image and the manifests artifact
      id-token: write # keyless cosign signing as this workflow
    steps:
      - uses: step-security/harden-runner@<full-commit-sha> # vX.Y.Z
        with:
          egress-policy: audit
      - uses: actions/checkout@<full-commit-sha> # vX.Y.Z
        with:
          persist-credentials: false
      - uses: devantler-tech/.github/actions/publish-app@<full-commit-sha> # vX.Y.Z
        with:
          app-name: my-app
          app-manifest: base/deployment.yaml # optional; default deployment.yaml
```

### Publish a prebuilt WebApp

```yaml
      - uses: devantler-tech/.github/actions/publish-app@<full-commit-sha> # vX.Y.Z
        with:
          mode: prebuilt-webapp
          app-name: my-site
          prebuilt-image-digest: sha256:<digest>
          prebuilt-public-digest: <sha256-hex>
          prebuilt-ci-run-id: "<run-id>"
          prebuilt-ci-run-attempt: "<attempt>"
```

### Publish manifests only

```yaml
      - uses: devantler-tech/.github/actions/publish-app@<full-commit-sha> # vX.Y.Z
        with:
          mode: manifests
          oci-name: devantler-tech/github-config # optional
```

## Not covered

- **Recovery** of a release whose version tags were lost after signing is not part of this action
  yet; the reusable workflows keep their recovery modes until a follow-up carries it over.
- The reusable `publish-app.yaml` and `publish-manifests.yaml` workflows are unchanged and keep
  their shared-publisher identity until every consumer has moved.
