# Create Issues from TODOs

Scan code for TODO comments and automatically create corresponding GitHub issues using the workflow's GitHub token. Project integration uses a separate GitHub App token. The calling job needs `contents: read` and `issues: write`.

## Inputs

| Name                    | Description                                                                           | Required | Default   |
| ----------------------- | ------------------------------------------------------------------------------------- | -------- | --------- |
| `client-id`             | GitHub App Client ID for project integration (preferred over the deprecated `app-id`) | ❌¹      | -         |
| `app-id`                | GitHub App ID. **Deprecated** — use `client-id` instead                               | ❌¹      | -         |
| `app-private-key`       | GitHub App Private Key                                                                | ❌¹      | -         |
| `optional-project-auth` | Opt in to generating an App token only when a project is configured                   | ❌       | `"false"` |
| `project`               | GitHub Project to add issues to                                                       | ❌       | -         |
| `ignore`                | Regular expression matching repository-relative paths to ignore                       | ❌       | `""`      |
| `exclude-vendored`      | Exclude root `vendor/` and `third_party/` when `ignore` is empty                        | ❌       | `"false"` |

¹ By default, provide `app-private-key` and one of `client-id` or `app-id`, preserving existing callers' App authentication. Prefer `client-id`; `app-id` is deprecated. With `optional-project-auth: 'true'`, App authentication is only needed for a configured project; invalid project credentials fail before checkout or scanning. Without a project, this opt-in skips App-token generation and needs no App inputs.

## What counts as a TODO

The scanner treats the marker as a TODO in any letter case, wherever it appears in a comment,
including in ordinary prose, and titles the issue with the text that follows it. When a comment
only describes TODOs, hyphenate the word (`to-do`), or exclude the file with `ignore`.

With `exclude-vendored: "true"` and an empty `ignore`, the scanner excludes root
`vendor/` and `third_party/` directories. Nested directories and similarly named
paths remain eligible. A nonempty custom `ignore` takes precedence unchanged.
The compatibility default is off; consumer rollout and retirement of this flag
are tracked in [#394](https://github.com/devantler-tech/.github/issues/394).

## Usage

The containing job needs `contents: read` and `issues: write`.

### Standard TODO scanning

```yaml
steps:
  - name: Create issues from TODOs
    uses: devantler-tech/.github/actions/create-issues-from-todos@<full-commit-sha> # vX.Y.Z
    with:
      optional-project-auth: "true"
      exclude-vendored: "true"
```

### With project integration

```yaml
steps:
  - name: Create issues from TODOs
    uses: devantler-tech/.github/actions/create-issues-from-todos@<full-commit-sha> # vX.Y.Z
    with:
      client-id: ${{ vars.APP_CLIENT_ID }}
      app-private-key: ${{ secrets.APP_PRIVATE_KEY }}
      project: "organization/devantler-tech/1"
```

Replace `<full-commit-sha>` with the immutable commit of a reviewed catalogue release.

## Testing

The catalogue's action smoke opts in to optional project authentication and runs with contents-read permission against an offline Docker stand-in, without App credentials or live tracker updates. The actual action wrapper is exercised, including exact Docker arguments, environment forwarding and the preserved retry helper. Offline cases cover both input states and retain the default path's App-token forwarding; structural guards bind the authentication conditions and existing App inputs. Independent mutations verify that missing forwarding, retry bypasses, swallowed failures, live credentials and omitted required checks fail CI.

Run from the catalogue root:

```bash
bash .github/tests/test-todo-action.sh
bash .github/tests/test-todo-action-blocks.sh
bash .github/tests/test-todo-action-ci.sh
```

These fixtures prove wrapper behavior and credential isolation. A separate required CI job runs the action's actual Docker wrapper and pinned scanner image against real Git diffs and a strict offline API replay:

```bash
go -C .github/tests/todo-scanner test -race ./...
bash .github/tests/test-todo-scanner-ci.sh
bash .github/tests/test-todo-scanner.sh # requires Docker, Go, jq and yq
```

The scanner container has networking disabled and receives only a synthetic token. A test entrypoint imports the production supervisor with an independent strict replay transport, then invokes the image's unchanged scanner. Every request, complete issue payload and expected result must match; missing or unexpected operations fail the test. Cases cover standard and mixed-case comments, ignored paths and nearby paths, no findings, duplicate detection, removed comments, ambiguous closure and API errors. The image is pulled before isolation, while all scanner execution runs offline.

The action runs the digest-pinned scanner once under an owned API supervisor. Complete
issue, milestone and duplicate-search reads must succeed before later writes; search
pagination is joined before an exact-title decision. A rejected close cannot trigger
a closure comment. API, JSON and project-operation failures fail the action even
when the scanner exits zero. A completed close followed by a rejected comment remains
a failed partial operation, with the completed close count in the diagnostic.

GitHub's issue inventory may link later pages through its numeric repository route
and opaque navigation cursors. The supervisor accepts that route only when it matches
the runner's repository ID. Every page must retain the original filters and API origin;
duplicate cursors, contradictory page targets and incomplete chains fail before writes.

Project selectors accept `organization/owner/number` or `user/owner/number`, resolved by
the actual project number, and existing title selectors, resolved across all pages.
Missing or ambiguous projects, incomplete GraphQL data and rejected additions fail.
Issue writes use the workflow token; project operations use the separate App token.
No additional permissions are requested.

Image downloads may retry. The two unauthenticated language-rule downloads may retry
before any mutation is attempted. The scanner and API writes are never retried, including
when a write's response is lost. Rerunning a failed job is an operator decision after
checking any completed changes.

The action requires a Linux runner with Docker and network access for the pinned Go
compiler and scanner image. It builds a static supervisor from the same action commit,
preserves it outside the checkout, and mounts it read-only into the unchanged image.
