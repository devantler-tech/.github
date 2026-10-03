# Login to GHCR

Login to GitHub Container Registry (GHCR) for pulling or pushing container images.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `github-token` | GitHub token with `packages:read` (or `packages:write`) scope | ✅ | - |

## Usage

The containing job needs `packages: read` to pull private packages, or
`packages: write` when it also pushes packages.

```yaml
steps:
  - name: Login to GHCR
    uses: devantler-tech/.github/actions/login-to-ghcr@<full-commit-sha> # vX.Y.Z
    with:
      github-token: ${{ secrets.GITHUB_TOKEN }}
```
