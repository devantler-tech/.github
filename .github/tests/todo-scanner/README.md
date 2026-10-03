# Offline TODO scanner fixture

The catalogue runs the unchanged digest-pinned scanner with synthetic credentials,
networking disabled and a strict ordered API replay. A passing scenario means the
scanner consumed the complete expected request plan, returned the recorded exit
result, emitted every required diagnostic and emitted none of its forbidden results.
It does not mean every simulated API request succeeded.

The scenarios include healthy discovery, ignore rules, duplicates and closure, plus
diff failures and rejected issue reads, milestone reads, searches, creation, close
requests and closure comments. `InitialReads` replaces the normal issue and milestone
responses; `ForbiddenOutput` rejects misleading success messages in scenarios that
report an unsuccessful operation. Fixture validation runs before image execution.

Four vendor scenarios cover omitted and explicit-off inputs, opted-in exclusion
of root `vendor/` and `third_party/`, and a custom ignore expression taking
precedence. Their literal request plans retain nested and similarly named paths.
The resolver checks the action's fixed output and forwarding as data; it never
executes workflow expressions or action source.

The pinned scanner currently continues from a rejected search to a create attempt,
and from a rejected close request to a comment attempt. It can report unsuccessful
creation or closure while exiting zero. The rejection scenarios record those facts;
they do not repair or approve them. [Issue #367](https://github.com/devantler-tech/.github/issues/367)
tracks the consumer repair separately. A successfully closed issue followed by a
rejected closure comment is also recorded as a partial operation.

Go tests reject false success messages, missing diagnostics, incorrect exits,
incomplete request plans and unplanned writes after a failed read. The plan and input
tests preserve healthy controls alongside the rejected and partial observations.
Hosted CI executes the real Docker wrapper and image, and its result contributes to
the required aggregate check.
