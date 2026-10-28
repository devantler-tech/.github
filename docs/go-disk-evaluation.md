# Evaluate Go runner cleanup

Existing production callers retain unconditional cleanup. The small CI fixtures use a
32 GiB budget; that is not a budget for a large application.

## Large-consumer experiment

`Measure Go disk capacity` is a manual, default-off evaluation on reviewed `main`.
Enable its existing `enabled` input only after its source has passed normal review and CI.
It runs the same pinned KSail revision in four isolated Ubuntu jobs: build and race
coverage, each with unconditional cleanup and a 64 GiB capacity policy. Go cache
restoration is disabled. The commands still populate module and build caches, whose
disk use is included in the measurements; the identity receipt's `cache: false`
records the restoration setting. Each job has a 60-minute ceiling; the historical baseline
suggests roughly 60–70 aggregate runner minutes for one four-job cohort. Inspect one complete cohort
before deciding whether a specific unresolved question warrants another.

The experimental threshold comes from [run 37734975025, attempt 1](https://github.com/devantler-tech/.github/actions/runs/37734975025):
race coverage reduced sampled available space by 21,493,424 KiB, about 20.50 GiB.
Twice that observed demand plus 20 GiB reserve is about 61 GiB, rounded up to 64 GiB.
This is a conservative hypothesis for that immutable workload, not proof of a universal
safe budget. One-second sampling can miss shorter peaks and includes unrelated filesystem
activity. Current production revisions, cache restoration and other runner images need
their own evidence before adoption. Unknown capacity always retains cleanup.

Download the four `go-disk-<phase>-<policy>` artifacts after the run. They contain identity,
cleanup-decision, cleanup-usage and command-usage JSON, plus the installed toolchain.
Artifacts are retained for seven days, including partial evidence after failures.
The workflow fails if required observations are absent, unknown, malformed or bound to
another run, attempt, source, phase or policy. A successful build alone is insufficient.
Keep the artifact bytes with the issue's private validation record before they expire.

## Fixture CI comparison

A capacity experiment does not establish whole-CI feedback time. Compare complete native
first-attempt CI graphs for equivalent changed-path workloads at explicit base/head
revisions. An unmerged draft may first set the four tiny-fixture budgets to zero as a
conservative control, then restore their existing 32 GiB values. Finish the control run
before pushing the restored policy, because CI cancels superseded PR runs. Merge only
the restored policy after its own complete current-head validation and review.

Verify equal fixture blobs, called workflow/action implementations, commands, selected
job sets, installed toolchains, runner images and cache restoration outcomes. The intended
fixture budget difference is the variable. A differing cache outcome or runner image
does not support a matched comparison; record the limitation before choosing any repeat.

Report allocated jobs, summed cleanup execution, actual first-step-to-completion job
intervals, workflow creation-to-final-required-gate time and initial launch delay separately.
Creation-to-job-start includes dependency waiting as well as queueing; native timestamps
do not isolate every scheduling delay. Never label that whole interval pure queue time.
Include complete run, attempt and source identities and report an unchanged or slower
end-to-end result honestly. One pair is an observation, not a general causal speedup.

The remaining outcome and rollout belong to [#527](https://github.com/devantler-tech/.github/issues/527).
The portfolio burst and downstream deployment-delay criteria remain in
[#475](https://github.com/devantler-tech/.github/issues/475).
