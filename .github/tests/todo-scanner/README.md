# Offline TODO scanner fixture

The catalogue runs the unchanged digest-pinned scanner under the production API
supervisor with synthetic credentials, networking disabled and a strict ordered
API replay. Every scenario must consume its complete request plan, return the expected
supervised result, emit required diagnostics and avoid forbidden results.

Healthy controls cover discovery, ignore rules, mixed-case markers, duplicates,
removed comments, ambiguous closure and numeric project selection. Failure controls
cover initial and later-page reads, incomplete searches, rejected creation/closure,
partial close/comment operations, missing project data and rejected GraphQL mutations.
They require action failure and prohibit additional upstream operations after failure.
The scanner cannot hide failure by exiting zero.

`InitialReads` replaces issue/milestone responses; `StopAfterInitialFailure` ends the
upstream plan after a failed initial read. `Headers` supplies literal pagination
metadata, and `Project` enables synthetic project authentication. Expected payloads
are literal fixtures. Native negative controls remove source markers or corrupt
a payload expectation; each must fail for its own reason alongside healthy runs.

The image is acquired before isolation. Docker disables networking for every scanner
execution. The test entrypoint imports the production supervisor and invokes the
image's unchanged scanner. Its replay transport terminates outbound operations locally.
The action wrapper still supplies the reviewed read-only supervisor mount and a single
scanner execution. Host unit tests separately cover gzip responses, wide native IDs,
linked closed issues, uncertain mutation results and concurrent requests.

Four vendor cases retain omitted/explicit-off inputs, opted-in root-directory
exclusion and explicit-ignore precedence. Permission and workflow routing fixtures
remain separate from API behavior; no scenario writes to GitHub.
