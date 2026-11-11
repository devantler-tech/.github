#!/usr/bin/env bash
# Derive which selection-gated CI jobs read the root README.md or AGENTS.md
# from the tracked workflow and the code those jobs execute, then require the
# selector inventory to route README.md to exactly that set and AGENTS.md to
# none. A new reader, an unreviewed mention or a whole-checkout read fails.
#
# Usage: ci-selection-document-readers.sh ROOT INVENTORY_JSON WORKFLOW_JSON
#
# A job's executed code is its inline run/with text, its reusable workflow and
# every tracked shell, jq or Go file and local action or Go module it names,
# followed transitively. Data files are leaves. Every line of that code that
# names README or AGENTS.md, or copies, archives or walks the whole checkout,
# either makes the job a reader or appears with its exact trimmed text in the
# reviewed non-reading list below. AGENTS.md and whole-checkout reads have no
# reviewed reader and always fail.
set -euo pipefail
(($# == 3)) || {
  echo 'usage: ci-selection-document-readers.sh ROOT INVENTORY_JSON WORKFLOW_JSON' >&2
  exit 2
}
root="$1" inventory="$2" workflow="$3"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Reviewed mentions that do not read the repository's root documents:
# fixture data, messages and comments. Format: <source>|<exact trimmed line>.
cat >"$work/non-reading" <<'LINES'
.github/scripts/inspect-release-recovery/internal/inspection/inspection_test.go|entry["path"] = "README.md"
.github/tests/test-govulncheck-main-coverage.sh|fail "govulncheck's gate has no default-branch clause, so the path filter is the only gate on the default branch and a non-Go push (e.g. a README edit) leaves it unscanned while reporting green. Add: || github.ref == format('refs/heads/{0}', github.event.repository.default_branch) — see ksail#6373."
.github/workflows/validate-go-project-readonly.yaml|# alone means a push touching no Go path (a README edit) skips the scan, so the branch
actions/validate-retired-repo-links/main_test.go|{"retired link blocks", basic, "See https://github.com/example/retired/blob/main/README.md", 1, "docs/guide.md:1"},
actions/validate-shell-pipelines/cli_test.go|"README.md":                "producer | grep -q not-code\n",
actions/validate-shell-pipelines/cli_test.go|for _, scope := range []string{"", "missing", "../escape", "/tmp", ":(glob)*", "*.sh", "safe.sh\nmissing", "README.md", "./safe.sh"} {
actions/validate-shell-pipelines/cli_test.go|root := fixture(t, map[string]string{"safe.sh": "true\n", "README.md": "text\n"})
actions/validate-shell-pipelines/cli_test.go|root := fixture(t, map[string]string{"README.md": "text"})
.github/tests/test-go-filter-nested-modules-blocks.sh|# test (AGENTS.md, "Failure-mode coverage for gating workflows").
.github/tests/test-govulncheck-main-coverage-blocks.sh|# test (AGENTS.md, "Failure-mode coverage for gating workflows").
.github/tests/test-suite-default-branch-coverage-blocks.sh|# blocks-on-bad-input test (AGENTS.md, "Failure-mode coverage for gating workflows").
.github/tests/test-suite-default-branch-coverage.sh|# the opt-in input `test-default-branch` (AGENTS.md, *Shipping a new capability behind an
actions/run-dotnet-tests/action.yaml|config_path="$(find . -maxdepth 1 \( -type f -o -type l \) -iname 'nuget.config' -print -quit)"
.github/tests/test-govulncheck-main-coverage.sh|fail "the govulncheck job passes no 'allow-file' input, so a committed .govulncheck-allow.txt is ignored and every risk-accepted advisory blocks the scan — see AGENTS.md, *Tested invariants*."
.github/tests/test-suite-default-branch-coverage.sh|fail "the test job's gate does not reference '$flag_ref', so the default-branch run is not behind the opt-in input it is required to ship behind — a behaviour change landing on every consumer at once. See AGENTS.md, 'Shipping a new capability behind an opt-in flag'."
.github/tests/test-suite-default-branch-coverage.sh|fail "the test job references '$flag_ref' OUTSIDE the OR-group that holds the path filter, so it is AND-ed at the top level and a caller that does not opt in loses the diff-triggered suite it has today. The input must gate the default-branch arm only — see AGENTS.md, 'Shipping a new capability behind an opt-in flag'."
.github/tests/test-suite-default-branch-coverage.sh|fail "no OR-arm both references '$flag_ref' and carries the default-branch clause, so the default-branch run is not the thing the opt-in input actually gates. See AGENTS.md, 'Shipping a new capability behind an opt-in flag'."
.github/tests/test-suite-default-branch-coverage.sh|fail "an OR-arm of the test job's gate carries a ref/default-branch predicate without being gated by '$flag_ref', so the new default-branch behaviour reaches consumers that never opted in. Offending arm: ${arm}. See AGENTS.md, 'Shipping a new capability behind an opt-in flag'."
.github/workflows/validate-go-project-readonly.yaml|# reachable from more than one trigger receives it either way (AGENTS.md, *Gotchas*).
LINES

git -C "$root" ls-files >"$work/tracked"
# A reviewed exemption must still name a real tracked line; a stale one could
# otherwise silently excuse a future reader with the same text.
while IFS= read -r exemption; do
  file="${exemption%%|*}" text="${exemption#*|}"
  grep -qxF -- "$file" "$work/tracked" || { echo "FAIL: untracked non-reading exemption: $exemption" >&2; exit 1; }
  # Trim into a file first: grep -q closing a pipe early would fail pipefail.
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$root/$file" >"$work/trimmed"
  grep -qxF -- "$text" "$work/trimmed" || { echo "FAIL: stale non-reading exemption: $exemption" >&2; exit 1; }
done <"$work/non-reading"

jq -r '(.jobs | keys) - (.preserved | keys) | .[]' "$inventory" >"$work/gated"
[[ -s "$work/gated" ]] || { echo 'FAIL: no selection-gated jobs to inspect' >&2; exit 1; }
jq -r '[.jobs | to_entries[] | select(.value | index("README.md")) | .key] | sort | .[]' "$inventory" >"$work/routed"
if jq -e '[.jobs[] | .[] | select(. == "AGENTS.md")] | length > 0' "$inventory" >/dev/null; then
  echo 'FAIL: AGENTS.md has no gated reader and must not own selection' >&2
  exit 1
fi
# One record per gated job: a header, then its inline text with a fixed prefix.
jq -r --rawfile gated "$work/gated" '
  ($gated | split("\n") | map(select(length > 0))) as $ids |
  $ids[] as $id | .jobs[$id] as $job |
  if $job == null then error("gated job \($id) is missing from the workflow") else . end |
  "@@job \($id) \(($job.uses // "-") | sub("^(\\$|\\.)/"; "") | sub("@.*$"; ""))",
  ([($job.steps[]? | (.uses // empty), (.run // empty), ((.with // {}) | tostring))] | join("\n") | split("\n")[] | "| " + .)
' "$workflow" >"$work/jobs"

# Walk every job's executed code in one pass; files are read and classified once.
awk -v root="$root" -v tracked="$work/tracked" -v exempt="$work/non-reading" '
  function code(p) { return p ~ /\.(sh|bash|jq|go)$/ || p ~ /(^|\/)action\.ya?ml$/ }
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  # Executable tracked files a reference names: an exact code file, or every
  # code file of a local action or Go module directory.
  function expand(r,   i, out) {
    sub(/\/+$/, "", r); sub(/^\.\//, "", r)
    if (r in memo) return memo[r]
    out = ""
    if ((r in tracked_set) && code(r)) out = r
    if (r in unit) for (i = 1; i <= ntracked; i++)
      if (index(paths[i], r "/") == 1 && code(paths[i]) && paths[i] != r) out = out "\n" paths[i]
    memo[r] = out
    return out
  }
  function scan(line, dir, source,   s, tok) {
    s = line
    while (match(s, /(\.github|\.scripts|actions|scripts|tests)\/[A-Za-z0-9_.\/-]*[A-Za-z0-9_-]/)) {
      refs[source] = refs[source] "\n" substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    }
    s = line
    while (match(s, /[A-Za-z0-9_-]+\.(sh|bash|go|jq)/)) {
      refs[source] = refs[source] "\n" dir "/" substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    }
    if (line ~ mentions || line ~ whole) {
      tok = trim(line)
      if ((source "|" tok) in exempted) return
      if (tok ~ whole || index(tok, "AGENTS.md")) verdict[source] = verdict[source] "\nfail\t" source ": " tok
      else verdict[source] = verdict[source] "\nreader"
    }
  }
  function load(p,   line, dir) {
    if (p in loaded) return
    loaded[p] = 1; refs[p] = ""; verdict[p] = ""
    dir = p; if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
    while ((getline line < (root "/" p)) > 0) scan(line, dir, p)
    close(root "/" p)
  }
  function visit(p,   n, i, list, m, j, targets) {
    if (p in seen) return
    seen[p] = 1; load(p); emit(p)
    n = split(refs[p], list, "\n")
    for (i = 1; i <= n; i++) if (list[i] != "") {
      m = split(expand(list[i]), targets, "\n")
      for (j = 1; j <= m; j++) if (targets[j] != "") visit(targets[j])
    }
  }
  function emit(p,   n, i, list) {
    n = split(verdict[p], list, "\n")
    for (i = 1; i <= n; i++) {
      if (list[i] == "reader") reader = 1
      else if (index(list[i], "fail\t") == 1) print "FAIL\t" id ": " substr(list[i], 6)
    }
  }
  function finish(   n, i, list, m, j, targets) {
    if (id == "") return
    emit(inline)
    n = split(refs[inline], list, "\n")
    for (i = 1; i <= n; i++) if (list[i] != "") {
      m = split(expand(list[i]), targets, "\n")
      for (j = 1; j <= m; j++) if (targets[j] != "") visit(targets[j])
    }
    if (reusable != "-") {
      if (!(reusable in tracked_set)) { print "FAIL\t" id ": calls untracked " reusable; return }
      visit(reusable)
    }
    if (reader) print "READER\t" id
  }
  BEGIN {
    mentions = "README|AGENTS\\.md"
    whole = "(^|[^A-Za-z0-9_])(cp|rsync|tar|find|archive)[[:space:]][^|;&]*[[:space:]](\"?[$][{]?(root|repo_root|source_root|GITHUB_WORKSPACE)[}]?/?[.]?\"?|[.]|[.]/)([[:space:]]|$)"
    while ((getline line < tracked) > 0) {
      paths[++ntracked] = line; tracked_set[line] = 1
      if (line ~ /\/(action\.ya?ml|go\.mod)$/) { d = line; sub(/\/[^\/]*$/, "", d); unit[d] = 1 }
    }
    while ((getline line < exempt) > 0) exempted[line] = 1
  }
  /^@@job / {
    finish()
    id = $2; reusable = $3; reader = 0; delete seen
    inline = "ci.yaml#" id; refs[inline] = ""; verdict[inline] = ""
    next
  }
  { scan(substr($0, 3), ".", inline) }
  END { finish() }
' "$work/jobs" >"$work/verdicts"

if grep -q '^FAIL' "$work/verdicts"; then
  echo 'FAIL: unreviewed AGENTS.md or whole-checkout read in a selection-gated job:' >&2
  awk -F '\t' '$1 == "FAIL" { print $2 }' "$work/verdicts" >&2
  exit 1
fi
awk -F '\t' '$1 == "READER" { print $2 }' "$work/verdicts" | sort >"$work/readers"
if ! diff -u "$work/readers" "$work/routed" >"$work/diff"; then
  echo 'FAIL: README.md route differs from its tracked gated readers (- reader not routed, + routed non-reader):' >&2
  cat "$work/diff" >&2
  exit 1
fi
printf 'PASS: README.md routes to its %s tracked gated readers among %s gated jobs; AGENTS.md has none.\n' \
  "$(wc -l <"$work/readers" | tr -d ' ')" "$(wc -l <"$work/gated" | tr -d ' ')"
