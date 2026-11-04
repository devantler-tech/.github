# Ordinary Go Test storage observation

The required Go workflow can observe an ordinary Test job without replaying an
old source or cache archive. This is default-off instrumentation for #838. It is
not a capacity correction, quota proof, or completion of that issue.

A consumer's selected Go module may track the regular file
`.go-disk-observation.json` containing exactly:

```json
{"version":1,"test":true}
```

Only the direct, input-free organization-required `validate-go-project.yaml`
invocation reads this declaration. A reusable caller's false or omitted
`measure-disk-usage` input stays off, even if the caller uses a similarly named
workflow. Existing `measure-disk-usage: true` callers retain the original build,
test and coverage collector. This declaration changes neither their interface
nor their behavior. Missing declarations and `test:false` remain disabled;
unknown fields, duplicate keys, untracked files and symlinks are refused.

Observation does not select additional Go jobs. The required Test must already
be selected by its normal source/default-branch rules. Its cleanup policy, cache
restore/save rules, permissions and `go test` arguments stay the same, including
`-count=1` for an independently enabled PostgreSQL fixture. Consumer enablement
and real native artifact validation must follow publication separately.

The observer queries only named Go environment keys. It records the actual
workspace, selected module, module cache, build cache, toolchain, effective Go
temporary directory and runner temporary directory using fixed labels. Paths
and raw probe output stay private in the runner's temporary directory. Only
`go-disk-observation/public/report.json` is uploaded, with seven-day retention.
The artifact includes:

- Byte and inode filesystem counters, with opaque filesystem groups so paths
  sharing a filesystem can be recognized without disclosing device names.
- Bounded component sizes after setup, after cache restore, before the command,
  periodically during execution and on command exit. Between component walks,
  periodic frames retain filesystem counters with component sizes uncollected.
- The source and catalogue commits, repository, run/attempt/job, selected module
  and `go.mod`/`go.sum` SHA-256 values, keyed Go toolchain identity and runner image.
- The actual module/build cache primary keys, matched keys and hit outputs.
  These identify the restore decision; they do not establish archive byte identity.
- The original command result and an explicit completeness verdict. A failed Go
  command may have complete observations; successful Go execution does not imply
  complete observations.
- Each component walk's fixed result class (`measured`, `command-failed`, or
  `invalid-output`), bounded-probe exit status and coarse whole-second elapsed
  time. Absent and intentionally uncollected components have matching classes
  and null exit/time fields. A nonzero status does not identify a permission
  error or prove that the deadline fired; raw stdout and stderr are omitted.
  The Go-temp label also distinguishes an explicit Go environment value from
  the TMPDIR fallback or system default, without disclosing those paths. A
  fallback may cover shared temporary contents; no category proves exclusive
  Go ownership. Other labels use the fixed `fixed-label` source category.

Completeness also requires actual runner image identity and no retained unknown
component measurements, independently of the writable failure marker. Absent
paths and intentionally uncollected periodic component sizes remain distinct.
A command that finishes before its first periodic sample has no `during-command`
frame and is reported as `complete:false`, even when Go and observer shutdown
both succeed. Boundary samples cannot substitute for during-command coverage.
`command.completed` and `command.exit` describe Go. The separately persisted
`command.observerCompleted` starts false and changes only after verified sampler
shutdown and the final edge collection. Failed atomic completion writes leave
the earlier false record, so a later publisher cannot forget collection failure
when the auxiliary failure marker was unwritable.

An absent cache is reported as absent, with zero component size and explicitly
labelled nearest-existing-parent filesystem counters. It is never created or
relocated by the observer. Existing path symlinks follow the same effective
targets as Go; private observation state and evidence files reject symlinks.
Component sizes can overlap (for example module and workspace, or a toolchain
inside the module cache), so they must not be added together.

Each filesystem/component probe has a two-second deadline and one-second kill
grace. The shared rich-frame budget accounts for eight labels with two `df`
reads and up to two `stat` attempts each, seven component walks, and the initial
sample's `df`: forty probe attempts × three seconds, plus ten seconds of
process/JSON overhead, gives 130 seconds. Cooperative shutdown allows that frame
budget plus one sampler delay (131 seconds). The legacy single-filesystem edge
and cancellation bounds stay unchanged; no job or Go-command deadline is raised.
Samples have a nominal one-second
delay; component walks can lengthen the interval and can miss shorter peaks.
Component walks run at boundaries and every sixty periodic iterations. The
history is limited to 1,800 periodic iterations and 8 MiB. Failed, malformed,
partial, timed-out, interrupted or unwritable observations are incomplete;
observer failures never replace or repeat the wrapped Go command. Cancellation
retains the existing bounded process-group cleanup and signal result. A missing
artifact establishes no measurement. Cancellation or a forced runner shutdown
may leave no artifact at all.

Filesystem counters do not establish filesystem/user/project quota limits or
which process caused growth. Both quota limits and cache archive byte identity
remain explicitly `not-established`. The report is observational evidence from
the job, not a cryptographic attestation. No historical cache is reconstructed,
and no historical replay selector is introduced.

Run `bash .github/tests/test-go-disk-measurement.sh` for the actual collector,
admission, command/cleanup preservation and failure controls. Regenerate the
read-only workflow with `bash .github/scripts/generate-go-readonly.sh` after
changing production wiring. Required catalogue CI runs these controls; consumer
publication, opt-in/off proof and ordinary native acceptance remain separate.

## Go temporary storage route (#838)

The failing KSail Test jobs ran on runner image `20261018.50.1`. Their normal
cleanup left about 40 GiB free on the runner disk, yet every write that failed
was under the system temporary directory: the Go linker's output and
`vet.cfg`/`importcfg` in the go command's work directory, then the tests' own
fixtures. Writes to the module and build caches on the runner disk never
failed. The error was `disk quota exceeded`, which a size-limited tmpfs
reports and an unquota'd runner disk does not. An instrumented passing run on
image `20261026.180.1` found the system temporary directory on the same
filesystem as the runner disk. Its peak use during `go test ./...` was about
19.8 GiB: 6.5 GiB of module cache, 6.2 GiB of build cache and a transient
work directory of several GiB.

The build, test and coverage jobs therefore run one step, after cleanup and
before Go is installed, that sets `GOTMPDIR` to a directory under
`RUNNER_TEMP`. `RUNNER_TEMP` is on the runner disk that the cleanup reclaims and
measures. The step prints one `GO_TEMP_ROUTE` receipt with the filesystem type
and available KiB of two directories: the system temporary directory, where Go
wrote before (the "before" reading), and the routed directory, where it writes
now (the "after" reading). The receipt says
`unknown` when it cannot read them and still routes. Only the go command's work
directory moves. The tests' `TMPDIR`, the test command, cleanup, caches and
permissions do not change. A missing or relative `RUNNER_TEMP`, an occupied
path or an unwritable environment file fails the job.

Capacity requirement: the runner disk must hold the restored module cache,
the build cache and the transient work directory together. That is about
20 GiB for KSail's complete unit suite on a cold build cache. The system
temporary directory needs only the tests' own fixtures.

Limitations: the receipt is one reading before the command, not a peak, and
quota limits remain unread. The image-to-mount correlation comes from logs
and one observation report, not from the image's published layout. Consumers
pick the route up when they bump their pinned release. After that, the next
required Test runs on each image are the native readback.

Run `bash .github/tests/test-go-temp-route.sh` for the placement, receipt and
refusal controls.
