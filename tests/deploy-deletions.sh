#!/usr/bin/env bash

set -euo pipefail

# Pins scripts/validate-deploy-deletions.sh against fixture renders: a removed
# identity must be acknowledged by an exact per-resource line in the PR body, a
# stale acknowledgement fails, and anything the guard cannot judge exits 2 rather
# than passing. Each case names the exact exit code it expects, so a fail-closed
# exit can never be mistaken for a refused deletion or vice versa.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-deploy-deletions.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "deploy-deletions test: $*" >&2
  exit 1
}

for tool in yq comm; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool '$tool' is not installed"
done

# doc <kind> <name> [<namespace>] — one rendered document.
doc() {
  printf -- '---\napiVersion: repo.github.m.upbound.io/v1alpha1\nkind: %s\nmetadata:\n  name: %s\n' "$1" "$2"
  if [[ -n "${3:-}" ]]; then
    printf '  namespace: %s\n' "$3"
  fi
  printf 'spec:\n  forProvider:\n    name: %s\n' "$2"
}

# run_case <expected-exit> <label> <base-file> <head-file> <body-file> [<stderr-must-contain>...]
run_case() {
  local expected="$1" label="$2" base="$3" head="$4" body="$5"
  shift 5
  local out err rc=0
  out="$tmp/out"
  err="$tmp/err"
  bash "$validator" "$base" "$head" "$body" >"$out" 2>"$err" || rc=$?
  [[ "$rc" == "$expected" ]] ||
    fail "$label: expected exit $expected, got $rc (stderr: $(cat "$err"))"
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" "$err" "$out" ||
      fail "$label: expected output to mention '$needle' (stderr: $(cat "$err"); stdout: $(cat "$out"))"
  done
}

full="$tmp/base.yaml"
{
  doc Repository ksail
  doc Repository doggy-countdown
  doc Label "ksail-bug"
  doc Label "ksail-bug" "kube-system"
} >"$full"

# --- No deletion ---------------------------------------------------------------
same="$tmp/same.yaml"
cp "$full" "$same"
printf 'Ordinary body.\n' >"$tmp/body-empty.txt"
run_case 0 "identical renders pass" "$full" "$same" "$tmp/body-empty.txt" "no managed resource leaves"

# A resource that changes, or moves file, keeps its identity — not a deletion.
changed="$tmp/changed.yaml"
sed 's/^    name: ksail$/    name: ksail-renamed-in-spec/' "$full" >"$changed"
grep -q 'ksail-renamed-in-spec' "$changed" || fail "fixture: spec change did not apply"
run_case 0 "a spec change under the same identity passes" "$full" "$changed" "$tmp/body-empty.txt"

# Document order is irrelevant: the same set in a different order is no deletion.
reordered="$tmp/reordered.yaml"
{
  doc Label "ksail-bug" "kube-system"
  doc Label "ksail-bug"
  doc Repository doggy-countdown
  doc Repository ksail
} >"$reordered"
run_case 0 "reordered documents pass" "$full" "$reordered" "$tmp/body-empty.txt"

# --- Deletion without acknowledgement ------------------------------------------
minus_repo="$tmp/minus-repo.yaml"
{
  doc Repository ksail
  doc Label "ksail-bug"
  doc Label "ksail-bug" "kube-system"
} >"$minus_repo"
run_case 1 "removing a document without acknowledgement fails and names the fix" \
  "$full" "$minus_repo" "$tmp/body-empty.txt" \
  "Deletion-Acknowledged: Repository/doggy-countdown"

# A blanket or near-miss acknowledgement is not the exact identity.
printf 'Deletion-Acknowledged: Repository/*\nDeletion-Acknowledged: doggy-countdown\n' >"$tmp/body-blanket.txt"
run_case 1 "a blanket acknowledgement does not cover a specific identity" \
  "$full" "$minus_repo" "$tmp/body-blanket.txt" \
  "Deletion-Acknowledged: Repository/doggy-countdown"

# The prefix must begin the line: a mention inside prose does not acknowledge.
printf 'We discussed Deletion-Acknowledged: Repository/doggy-countdown earlier.\n' >"$tmp/body-prose.txt"
run_case 1 "an acknowledgement embedded in prose does not count" \
  "$full" "$minus_repo" "$tmp/body-prose.txt" \
  "Deletion-Acknowledged: Repository/doggy-countdown"

# --- Deletion with acknowledgement ---------------------------------------------
printf 'Retire the archived repo.\n\nDeletion-Acknowledged: Repository/doggy-countdown\n' >"$tmp/body-ack.txt"
run_case 0 "an exact acknowledgement passes" "$full" "$minus_repo" "$tmp/body-ack.txt" \
  "1 removed resource(s)" "Repository/doggy-countdown"

# CRLF bodies and leading whitespace (a list item, a quoted line) still match.
printf 'Body\r\n  Deletion-Acknowledged: Repository/doggy-countdown \r\n' >"$tmp/body-crlf.txt"
run_case 0 "a CRLF body with surrounding whitespace passes" "$full" "$minus_repo" "$tmp/body-crlf.txt"

# --- Intra-file document removal and namespaced identities -----------------------
# Cutting ONE document out of a multi-document file is a deletion a path diff
# cannot see; the namespaced twin of the same kind/name is a distinct identity.
minus_ns_label="$tmp/minus-ns-label.yaml"
{
  doc Repository ksail
  doc Repository doggy-countdown
  doc Label "ksail-bug"
} >"$minus_ns_label"
run_case 1 "removing only the namespaced twin fails on its namespaced identity" \
  "$full" "$minus_ns_label" "$tmp/body-empty.txt" \
  "Deletion-Acknowledged: Label/kube-system/ksail-bug"
printf 'Deletion-Acknowledged: Label/ksail-bug\n' >"$tmp/body-wrong-twin.txt"
run_case 1 "acknowledging the cluster-scoped twin does not cover the namespaced one" \
  "$full" "$minus_ns_label" "$tmp/body-wrong-twin.txt" \
  "Deletion-Acknowledged: Label/kube-system/ksail-bug" "does not remove"
printf 'Deletion-Acknowledged: Label/kube-system/ksail-bug\n' >"$tmp/body-ns.txt"
run_case 0 "the namespaced acknowledgement passes" "$full" "$minus_ns_label" "$tmp/body-ns.txt"

# Several removals need several lines; a partial acknowledgement still fails and
# names only what is missing.
minus_two="$tmp/minus-two.yaml"
{
  doc Repository ksail
  doc Label "ksail-bug"
} >"$minus_two"
run_case 1 "a partial acknowledgement fails on the remaining identity" \
  "$full" "$minus_two" "$tmp/body-ack.txt" \
  "Deletion-Acknowledged: Label/kube-system/ksail-bug"
if bash "$validator" "$full" "$minus_two" "$tmp/body-ack.txt" 2>&1 | grep -qF 'Deletion-Acknowledged: Repository/doggy-countdown'; then
  fail "partial acknowledgement: the already-acknowledged identity must not be re-listed as missing"
fi
printf 'Deletion-Acknowledged: Repository/doggy-countdown\nDeletion-Acknowledged: Label/kube-system/ksail-bug\n' >"$tmp/body-two.txt"
run_case 0 "acknowledging every removal passes" "$full" "$minus_two" "$tmp/body-two.txt" "2 removed resource(s)"

# --- Stale acknowledgement -----------------------------------------------------
run_case 1 "an acknowledgement for a resource still present fails" \
  "$full" "$same" "$tmp/body-ack.txt" "does not remove" "Repository/doggy-countdown"

# --- Fail-closed: exit 2, never a pass --------------------------------------------
: >"$tmp/empty.yaml"
run_case 2 "an empty head render is UNKNOWN, not a mass deletion" "$full" "$tmp/empty.yaml" "$tmp/body-empty.txt" "renders no documents"
run_case 2 "an empty base render is UNKNOWN, not a clean pass" "$tmp/empty.yaml" "$full" "$tmp/body-empty.txt" "renders no documents"
{
  doc Repository ksail
  printf -- '---\napiVersion: v1\nkind: Label\nmetadata:\n  labels:\n    x: y\n'
} >"$tmp/nameless.yaml"
run_case 2 "a document without metadata.name is UNKNOWN" "$full" "$tmp/nameless.yaml" "$tmp/body-empty.txt" "no kind or no metadata.name"
run_case 2 "a missing body file is UNKNOWN" "$full" "$same" "$tmp/does-not-exist.txt" "not a readable file"
rc=0
bash "$validator" "$full" "$same" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "missing arguments: expected exit 2, got $rc"

# Missing yq must be exit 2, not a pass. A PATH holding only the coreutils the
# validator needs (and no yq) proves the guard does not silently continue.
bin="$tmp/bin"
mkdir -p "$bin"
for t in bash sort comm sed tr wc cat printf; do
  p="$(command -v "$t")" && ln -s "$p" "$bin/$t" || true
done
rc=0
PATH="$bin" bash "$validator" "$full" "$same" "$tmp/body-empty.txt" >/dev/null 2>"$tmp/err-noyq" || rc=$?
[[ "$rc" == 2 ]] || fail "missing yq: expected exit 2, got $rc ($(cat "$tmp/err-noyq"))"
grep -qF 'yq is required' "$tmp/err-noyq" || fail "missing yq: expected the message to name yq"

# --- Negative control: the guard actually evaluates the renders it is given ------
# Feed the SAME file as base and head where a deletion was expected: the case
# must now PASS, proving the earlier failure came from the diff and not from the
# body alone.
run_case 0 "negative control: identical renders pass even with an empty body" "$minus_repo" "$minus_repo" "$tmp/body-empty.txt"

echo "deploy-deletions test: OK"
