# Create Issues from TODOs

Scan code for TODO comments and automatically create corresponding GitHub issues using the workflow's GitHub token. Project integration uses a separate GitHub App token. The calling job needs `contents: read` and `issues: write`.

## Inputs

| Name | Description | Required | Default |
|------|-------------|----------|---------|
| `client-id` | GitHub App Client ID for project integration (preferred over the deprecated `app-id`) | ❌¹ | - |
| `app-id` | GitHub App ID. **Deprecated** — use `client-id` instead | ❌¹ | - |
| `app-private-key` | GitHub App Private Key | ❌¹ | - |
| `optional-project-auth` | Opt in to generating an App token only when a project is configured | ❌ | `"false"` |
| `project` | GitHub Project to add issues to | ❌ | - |
| `ignore` | Regular expression matching repository-relative paths to ignore | ❌ | `""` |

¹ By default, provide `app-private-key` and one of `client-id` or `app-id`, preserving existing callers' App authentication. Prefer `client-id`; `app-id` is deprecated. With `optional-project-auth: 'true'`, App authentication is only needed for a configured project; invalid project credentials fail before checkout or scanning. Without a project, this opt-in skips App-token generation and needs no App inputs.

## What counts as a TODO

The scanner treats the marker as a TODO in any letter case, wherever it appears in a comment,
including in ordinary prose, and titles the issue with the text that follows it. When a comment
only describes TODOs, hyphenate the word (`to-do`), or exclude the file with `ignore`.

## Usage

### Standard TODO scanning

```yaml
steps:
  - name: Create issues from TODOs
    uses: devantler-tech/.github/actions/create-issues-from-todos@<full-commit-sha> # vX.Y.Z
    with:
      optional-project-auth: 'true'
      ignore: "^third_party/"
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

These fixtures prove wrapper behavior and credential isolation. They do not execute the scanner image or prove comment discovery and issue-payload construction; those require separate scanner fixtures.
