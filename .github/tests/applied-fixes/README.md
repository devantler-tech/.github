# Applied-fixes behavioral tests

The test driver extracts all three Bash steps from `apply-signed-fixes.yaml` with
`yq` and executes them unchanged in disposable Git repositories. The only fake
external boundary is GitHub's API. Its requests, returned verification objects,
and mutation count are recorded locally. No token or network access is needed.

Production signing stays inline. The privileged job may not run code from the
consumer checkout; `test-lint-signed-commit.sh` continues to enforce its action
inventory, content digests, and credential boundaries. Test helpers and extracted
scripts live outside the consumer repository, so the committed payload contains
only the intended consumer changes.

## Behavioral contract

- Tip checks use the event head and only require a signature for this lane's own
  applied-fixes headline. They also run when the replacement invocation has no patch.
- Ordinary no-change inputs make no API call from the commit step. Already-applied
  fixes still verify the head instead of treating an empty change set as sufficient.
- Changes preserve exact bytes and paths, including binary and large files, and
  bind the mutation to the repository, branch, message, and expected head.
- Unsupported file modes, failed Git discovery, conflicting patches, stale heads,
  failed API calls, and malformed responses fail instead of reporting completion.
- A commit is created on a bounded temporary branch while the consumer stays at
  its original head. Its exact identity, single parent and verified signature
  must match before publication.
- One atomic, non-forced ref transaction advances the consumer using its expected
  original head and deletes the staging ref using its expected signed tip.
  Concurrent changes reject the whole transaction.
- Failed verification leaves the consumer unchanged. Cleanup compares the known
  staging tip; a collision, unknown acknowledgment or concurrent staging update
  never authorizes deleting another ref or tip.
- A failed cleanup-plan write retains the staging ref, emits a warning, removes
  the local workdir, and preserves the original verification-failure status.

[`createCommitOnBranch`](https://docs.github.com/en/graphql/reference/commits#createcommitonbranch)
updates the staging branch as part of the commit mutation. The subsequent
verification precedes the consumer update through
[`updateRefs`](https://docs.github.com/en/graphql/reference/git#updaterefs).
The fake API models both refs independently and checks every precondition before
applying any member of the transaction. Tests assert their final state and the
verification/publication order, including lost responses after a completed write.

Temporary branches use the runner's unique check-run ID and can trigger ordinary
consumer branch/create workflows. They are not private storage. Cancellation or
an unknown API response can retain one; the handler reports uncertain cleanup
instead of blindly deleting it. A lost promotion acknowledgment can report
failure after the signed consumer update completed; it never authorizes a retry
that overwrites a concurrent head.

The fixtures prove caller behavior at an API boundary, not GitHub's real signature
issuance or a consumer rollout. Existing hosted signer jobs supply separate live
evidence. Deliberately weakened workflow copies prove these tests detect missing
verification and incorrect request identity; they never change the checked-in
workflow or refresh its security digests.
