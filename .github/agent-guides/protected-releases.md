# Protected release consumers

`create-release.yaml` supports an opt-in `protected-release: true` mode. It uses the same release
steps, permissions, queue and recovery behavior as the existing mode, but the release job names
the fixed `release` environment. It reads only that environment's `RELEASE_APP_CLIENT_ID` variable
and `RELEASE_APP_PRIVATE_KEY` secret. The protected private key is not a workflow-call input,
and an absent protected key never falls back to the legacy App key.

The two jobs keep their common publishing steps in parity through the existing offline
boundary checks. Explicit job blocks preserve legacy callers without creating an environment
for them. YAML aliases cannot currently replace those blocks: the catalogue's credential auditor
rejects aliases rather than assuming their execution semantics.

## Provision before adoption

Configure the consumer's `release` environment to permit the `main` branch only, with no tag
deployment rule. Keep the default branch protected and disallow administrative environment
bypass. Use a release App identity installed only on the approved consumer repositories, with
only the permissions the release uses. An environment name alone provides no protection:
GitHub automatically creates missing environments without protection rules or secrets.

Place the dedicated App's client ID and private key only in the protected environment. The
credential custodian must verify that no repository secret, eligible organization secret,
alternative App identity, or other unprotected copy can provide the same publishing authority.
Prepare changes to shared credentials and installations for the maintainer to apply; do not
copy secret values into Git, logs, issues, comments, or operator reports.

Use an immutable reviewed shared-workflow release:

```yaml
jobs:
  release:
    uses: devantler-tech/.github/.github/workflows/create-release.yaml@<full-commit-sha>
    with:
      protected-release: true
      disable-issue-side-effects: true
```

The source check also requires the protected default branch before minting the App token.
This is defense in depth; it does not replace the independently enforced environment and
credential-custody boundary.

## Acceptance and rollback

Before claiming adoption, record private metadata readback of the environment's branch rules,
App scope and credential locations. Dispatch a credential-free negative control from a reviewed
test branch: the protected release job must be refused before its first step. Observe a real
default-branch release through the protected job, then exercise the same job in dry-run mode at
the already released commit to confirm the existing tag/release recovery decision. Confirm the
tag, release and immutable release attestation independently. Offline tests and a green compiler
check do not establish these live acceptance conditions.

On failure, keep publication held and correct the environment, custody or reviewed workflow.
Do not restore an unprotected credential copy or switch the consumer back to the legacy mode as
a recovery shortcut. Existing immutable releases remain available while the release path is
repaired.

GitHub documents [environment protection and secret availability](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
and [the write-access trust boundary for repository secrets](https://docs.github.com/en/actions/reference/security/secure-use).

For local syntax checks, actionlint 1.7.12 treats a reusable workflow's declared caller secrets as
the complete secret context. It does not recognize the additional job environment secret. Keep
the environment key out of the caller interface; restrict any local compatibility filter to
the exact `release_app_private_key` undefined-property diagnostic. GitHub's native compiler and
the live protected release observations remain required.
