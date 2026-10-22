# Run Dotnet Tests

Test .NET solutions or projects across multiple platforms with code coverage reporting. Sets up the .NET 9 (STS) and .NET 10 (LTS) SDKs side-by-side, optionally restores private packages from GitHub Packages without persisting credentials, runs tests with coverage collection, and uploads the report to **GitHub Code Quality** (native PR coverage) on authenticated runs.

> **Permissions:** the calling job must grant `code-quality: write` for the GitHub Code Quality upload. The coverage is merged into a single Cobertura report (via ReportGenerator) and uploaded once, from the Linux matrix leg only. The upload is best-effort (it never fails the build), requires the repo's **Code Quality** to be enabled (_Settings → Code quality_), and is skipped when `github-token` is empty.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `github-token` | GitHub token for authenticated GitHub Packages restore and Code Quality upload. Omit it when testing untrusted pull-request code. | ❌ | `""` |
| `working-directory` | Directory to run the tests in | ❌ | `.` |

## Usage

### Basic

```yaml
steps:
  - name: Test .NET project
    uses: devantler-tech/.github/actions/run-dotnet-tests@<full-commit-sha> # vX.Y.Z
```

### Custom working directory

```yaml
steps:
  - name: Test .NET project
    uses: devantler-tech/.github/actions/run-dotnet-tests@<full-commit-sha> # vX.Y.Z
    with:
      working-directory: src/MyProject
```

### Test runners

The action picks the test command from the runner your project uses:

- **VSTest (the default):** runs `dotnet test` with the Coverlet collector (`--collect:"XPlat Code Coverage"`).
- **Microsoft.Testing.Platform:** used when the nearest `global.json` sets `"test": { "runner": "Microsoft.Testing.Platform" }`. This is the runner xUnit v3 4.x needs on the .NET 10 SDK.
  - If a project references `Microsoft.Testing.Extensions.CodeCoverage`, coverage is collected in Cobertura format with `--coverage`.
  - Otherwise tests still run, and a notice explains that coverage was skipped.

Pass `github-token` only for trusted runs that need to restore private packages from
GitHub Packages. Authentication is scoped to that restore step, so subsequent tests
cannot read the credential from their process environment or the user NuGet configuration.
Credential-free runs also skip the token-bearing GitHub Code Quality upload.

## Repository-owned CI

Put the job in your repository's own CI workflow and call this action. The action runs on
the current runner; a matrix supplies multiple operating systems. No shared .NET test workflow
is exported. This complete job keeps pull-request tests credential-free:

```yaml
jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    permissions:
      contents: read
      packages: read
      code-quality: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: devantler-tech/.github/actions/run-dotnet-tests@<full-commit-sha> # vX.Y.Z
        with:
          github-token: ${{ github.event_name != 'pull_request' && secrets.GITHUB_TOKEN || '' }}
```

Omit `github-token` entirely when authenticated restore and coverage upload are unnecessary.
Any explicit authenticated pull-request path belongs to the calling repository: require its
own opt-in, a same-repository head and a non-bot pull-request author. Do not trust `github.actor`
or let fork and bot code opt itself into credentials. The action does not decide whether its
caller is trusted.
