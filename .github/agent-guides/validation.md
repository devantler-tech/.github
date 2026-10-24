# Validation and publication contracts

Read this guide before changing catalogue validation, to-do forwarding, publication or release recovery. Validation includes naming, shell pipelines and retired links. Commands and code paths are relative to the repository root.

**CI run budgets:** `check-ci-run-budget` is default-off and metadata-only.
Enabled calls bind one completed run, repository, full head, workflow path,
event and stable attempt. Complete latest-job pages determine actual completion;
mutable workflow updates never do. Reruns retain original creation time.
Below 900 seconds passes; native failures and over-budget runs fail, while
incomplete or changed evidence is unknown. Disabled and unsuccessful calls expose
no validation output. Keep the Linux/macOS shipped-step and native-command
controls in required CI. This is a single-run primitive, not whole-PR enforcement;
consumer adoption, aggregation and flag retirement remain under #654.

**Production to-do input forwarding:** the reusable scanner exposes the composite's
optional-project integration choices while retaining its existing defaults.
The generated read-only workflow runs the exact production steps with an empty
project and all paths excluded in required CI; both offline dry-run calls remain.
Keep default/forwarding controls, projection parity and all three caller boundaries
covered. This proves the no-project wrapper path; #340 still owns live project
association, consumer rollout and flag retirement. The separately generated default
fixture retains the production defaults and native conditional routing, with only
offline dependencies. Keep both its compatibility caller and missing-token control
required; this fixture never proves live token generation or project association.

**Verified publication:** Every normal publisher authenticates and establishes normalized version absence before its first write and again before promotion. Preserve structured missing-version evidence, fail-closed authentication/read errors, both application targets, immutable helper checkout and removal before the image build. Default publication stages and signs produced digests before exposing version and source-SHA image tags or moving stable `latest`, preserves `latest` for prereleases, and never exposes release tags through builder metadata. Opt-in verified publication additionally checks exact signature identities and signed claims. Serialize default, opted-in and recovery publishers for the same target within a caller repository with a shared concurrency group, queue:max and no cancellation. Keep `.github/tests/test-unpublished-version.sh`, promotion controls and the native disposable-registry proof in required CI. Other writers can race the final check; registry tag writes are not atomic across repositories. #371 owns consumer rollout of verified publication.

**Explicit manifests recovery:** Default-off `enable-signed-recovery` requests only the original version alias, with signed promotion and caller pinning required before any legacy write. Verify the original catalogue identity and all original source/version/run claims, restore only authenticated missing versions, treat matching versions as no-ops, refuse contradictory or ambiguous reads, and always preserve `latest`. Keep recovery boundary, interruption/readback controls and native Flux/registry/cryptographic tests in required CI. The native key fixture proves signed claims and registry bytes, not production OIDC. Cross-repository publisher identity migration remains #242; complete recovery rollout remains #425.

The configuration caller guard separately requires the exact consumer-approved signing revision
and the publisher workflow/helper Git blobs and regular-file modes. Even an unrelated release with
unchanged publisher contents changes its certificate identity. Deploy and independently read back
consumer approval before changing the guard's recorded revision and the caller; never treat content
equivalence as that approval. Changed contents also require review before updating the recorded
blobs. Missing commits are read through a disposable object store. The promotion suite rejects an
unapproved byte-identical release and exercises an explicitly approved release, changed helpers,
modes and unsafe inputs. CI's record does not replace the deployed verifier's exact-revision gate.

**Explicit application recovery:** The same default-off mode verifies both original signatures with all nine paired publication claims before reading both version aliases. Any conflict or unknown read prevents all writes; only missing aliases are restored, with digest readback and matching retries producing no writes. Keep `.github/tests/test-app-recovery.sh` and the native single-platform Buildx/Flux proof required. Never rebuild, re-sign or move `latest` during recovery. Registry writes have no compare-and-set or cross-repository transaction; the shared queue and final readback cannot fence unrelated writers.

**Prebuilt WebApp publication:** Default-off `enable-prebuilt-webapp` requires
caller pinning and signed promotion, and cannot combine with recovery. Before
any registry write, verify the original caller-owned public main-push CI attempt,
image signature and complete production-template SLSA statement against the
tagged source, public artifact digest and fixed caller CI identity. A private,
incomplete, failed or changed attempt is unsupported. Do not accept an arbitrary
image repository, signer or caller-provided source identity. Pin only the image
of one source-owned WebApp whose name, namespace and spec name match the caller;
reject linked/special deployment files. This is not complete controller schema
validation. Sign and verify both promoted digests with all fourteen paired
claims, retaining the original image provenance. Keep helper refusal/pinning,
promotion mutation, native cryptographic and workflow-interface controls in
required CI. Legacy recovery must refuse prebuilt-marked evidence even when the
new mode input is omitted. Caller/verifier adoption remains separate; #684 owns
the finite rollout gate review and retirement.

**Manifest naming:** Every `validate-naming` call validates the caller's versioned
configuration. Keep the Linux/macOS clean fixtures, seeded naming violations and
missing-configuration failures required in CI. Failed calls never report a
`validated` output.

**Shell pipeline assertions:** `lint-shell-pipelines` invokes the shared guard over
the real script directories declared in that CI job's
`SCAN_PATHS`. Keep new script-owning directories in this scope and extend
`.github/tests/test-shell-pipeline-adoption.sh` with a representative script.
The test proves each scope rejects a deliberate regression without executing the
scanned scripts. Intentionally invalid product fixtures stay in `.github/fixtures`
and are exercised separately. Repair findings by checking producer completion
before searching captured output; do not blanket-exempt the repository's scripts.
Every shared-action call validates. Linux/macOS fixtures cover clean, unsafe and
malformed scans. An invalid scope must fail without a `validated` output.

**Retired repository links:** `validate-retired-repo-links` is a default-on,
read-only Go validator with no module dependencies; `enabled: "false"` switches it
off without removing the step. Keep the default, both explicit states, real
good/bad action fixtures on Linux/macOS, and the required-check wiring covered.
Successful calls expose their exact action module directory for same-job consumer
refusal controls; disabled and failed calls expose neither validation nor source
outputs. Keep the native usable-source assertions and
`.github/tests/test-retired-repo-links-source.sh` passing when changing this boundary.
Configuration belongs to each consumer; never hard-code retired portfolio names
or blanket historical exemptions in the action. Exceptions require an exact
file, repository and reason. The `enabled` input is a supported off switch, not a
temporary rollout flag ([#269](https://github.com/devantler-tech/.github/issues/269)).

