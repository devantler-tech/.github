# TODO API supervisor

This zero-dependency Go module supervises the unchanged digest-pinned TODO scanner.
The CLI reads only the action's existing inputs, starts a scoped loopback API/TLS
proxy, invokes the scanner once, and independently judges the operations it observed.

REST routes are bound to the configured repository. List/search pages are buffered
until complete; earlier last-page commitments remain binding across the chain.
Partial, inconsistent, malformed or over-limit evidence fails. Search absence cannot
contradict verified inventory or mutations. Because the pinned scanner submits titles
as unescaped search syntax, titles containing qualifiers, Boolean operators, quoted
expressions, wildcards or negated terms fail before searching or writing.
Linked issue targets receive an independent scoped read when absent from the open
inventory. Project discovery resolves numbers directly and titles across complete
cursor pages; only verified project/issue IDs may be added.

The first failed operation latches failure and denies subsequent requests. A mutation
is marked attempted before sending, so a lost response cannot authorize retries.
Completed close operations are retained in partial-failure diagnostics. The child
process's zero exit does not override an observed failure.

Only the known language-rule routes receive read retries before mutation. Redirects
are disabled. The child receives an ephemeral scoped CA and controlled proxy settings;
inherited proxy/CA overrides are removed. Tokens remain in their respective REST and
project headers and are absent from language-rule requests and diagnostics.

Run `go test -race ./...` and `go vet ./...`. Hosted catalogue CI also exercises this
module against the real pinned scanner in a container with networking disabled.
