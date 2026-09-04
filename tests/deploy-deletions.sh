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

group="repo.github.m.upbound.io"

# doc <kind> <name> [<namespace>] [<apiVersion>] — one rendered document.
doc() {
  printf -- '---\napiVersion: %s\nkind: %s\nmetadata:\n  name: %s\n' "${4:-$group/v1alpha1}" "$1" "$2"
  if [[ -n "${3:-}" ]]; then
    printf '  namespace: %s\n' "$3"
  fi
  printf 'spec:\n  forProvider:\n    name: %s\n' "$2"
}

# run_case <expected-exit> <label> <base-file> <head-file> <body-file> [<output-must-contain>...]
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

# assert_absent <label> <base> <head> <body> <needle> — the combined output must NOT mention it.
assert_absent() {
  local label="$1" base="$2" head="$3" body="$4" needle="$5"
  if bash "$validator" "$base" "$head" "$body" 2>&1 | grep -qF -- "$needle"; then
    fail "$label: output must not mention '$needle'"
  fi
}

full="$tmp/base.yaml"
{
  doc Repository ksail
  doc Repository doggy-countdown
  doc Label "ksail-bug"
  doc Label "ksail-bug" "kube-system"
} >"$full"
repo_id="Repository.$group/doggy-countdown"
ns_label_id="Label.$group/kube-system/ksail-bug"

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

# A VERSION bump within the same group keeps the identity — not a deletion.
bumped="$tmp/bumped.yaml"
sed "s|^apiVersion: $group/v1alpha1$|apiVersion: $group/v1beta1|" "$full" >"$bumped"
grep -q 'v1beta1' "$bumped" || fail "fixture: version bump did not apply"
run_case 0 "an apiVersion bump within the group passes" "$full" "$bumped" "$tmp/body-empty.txt"

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
  "$full" "$minus_repo" "$tmp/body-empty.txt" "Deletion-Acknowledged: $repo_id"

# A blanket, group-less or name-only acknowledgement is not the exact identity.
printf 'Deletion-Acknowledged: Repository/*\nDeletion-Acknowledged: Repository/doggy-countdown\nDeletion-Acknowledged: doggy-countdown\n' >"$tmp/body-blanket.txt"
run_case 1 "a blanket or group-less acknowledgement does not cover the identity" \
  "$full" "$minus_repo" "$tmp/body-blanket.txt" "Deletion-Acknowledged: $repo_id"

# The prefix must begin the line: a mention inside prose does not acknowledge.
printf 'We discussed Deletion-Acknowledged: %s earlier.\n' "$repo_id" >"$tmp/body-prose.txt"
run_case 1 "an acknowledgement embedded in prose does not count" \
  "$full" "$minus_repo" "$tmp/body-prose.txt" "Deletion-Acknowledged: $repo_id"

# An acknowledgement hidden inside an HTML comment is invisible in the rendered
# body, so it is not an acknowledgement — single-line and multi-line forms.
printf '## Why\n\n<!--\nDeletion-Acknowledged: %s\n-->\n' "$repo_id" >"$tmp/body-hidden.txt"
run_case 1 "an acknowledgement inside a multi-line HTML comment does not count" \
  "$full" "$minus_repo" "$tmp/body-hidden.txt" "Deletion-Acknowledged: $repo_id"
printf '<!-- Deletion-Acknowledged: %s -->\n' "$repo_id" >"$tmp/body-hidden1.txt"
run_case 1 "an acknowledgement inside a single-line HTML comment does not count" \
  "$full" "$minus_repo" "$tmp/body-hidden1.txt" "Deletion-Acknowledged: $repo_id"

# --- Deletion with acknowledgement ---------------------------------------------
printf 'Retire the archived repo.\n\nDeletion-Acknowledged: %s\n' "$repo_id" >"$tmp/body-ack.txt"
run_case 0 "an exact acknowledgement passes" "$full" "$minus_repo" "$tmp/body-ack.txt" \
  "1 removed resource(s)" "$repo_id"

# CRLF bodies, surrounding whitespace, a list or quote marker, backticks around
# the identity, and an unterminated final line (CI writes the body with
# `printf '%s'`) all still match.
printf 'Body\r\n  Deletion-Acknowledged: %s \r\n' "$repo_id" >"$tmp/body-crlf.txt"
run_case 0 "a CRLF body with surrounding whitespace passes" "$full" "$minus_repo" "$tmp/body-crlf.txt"
printf -- '- Deletion-Acknowledged: %s\n' "$repo_id" >"$tmp/body-list.txt"
run_case 0 "a list-item acknowledgement passes" "$full" "$minus_repo" "$tmp/body-list.txt"
# shellcheck disable=SC2016 # the backticks are literal body text
printf '> Deletion-Acknowledged: `%s`\n' "$repo_id" >"$tmp/body-quote-ticks.txt"
run_case 0 "a quoted, backticked acknowledgement passes" "$full" "$minus_repo" "$tmp/body-quote-ticks.txt"
printf 'Deletion-Acknowledged: %s' "$repo_id" >"$tmp/body-noeol.txt"
run_case 0 "an unterminated final line passes" "$full" "$minus_repo" "$tmp/body-noeol.txt"
# Text after a closed HTML comment on the same line is still visible.
printf '<!-- reviewed --> Deletion-Acknowledged: %s\n' "$repo_id" >"$tmp/body-after-comment.txt"
run_case 0 "an acknowledgement after a closed HTML comment passes" "$full" "$minus_repo" "$tmp/body-after-comment.txt"

# --- API group is part of the identity ---------------------------------------------
# Moving a resource to another group prunes the old managed resource, so it IS a
# deletion of the old identity (and an addition of the new one).
moved_group="$tmp/moved-group.yaml"
{
  doc Repository ksail
  doc Repository doggy-countdown "" "repo.github.upbound.io/v1alpha1"
  doc Label "ksail-bug"
  doc Label "ksail-bug" "kube-system"
} >"$moved_group"
run_case 1 "moving a resource to another API group is a deletion of the old identity" \
  "$full" "$moved_group" "$tmp/body-empty.txt" "Deletion-Acknowledged: $repo_id"
printf 'Deletion-Acknowledged: Repository.repo.github.upbound.io/doggy-countdown\n' >"$tmp/body-new-group.txt"
run_case 1 "acknowledging the NEW group's identity does not cover the old one" \
  "$full" "$moved_group" "$tmp/body-new-group.txt" "Deletion-Acknowledged: $repo_id" "does not remove"
run_case 0 "acknowledging the old group's identity passes" "$full" "$moved_group" "$tmp/body-ack.txt"

# A core-group document (apiVersion without a "/") carries no `.<group>`.
core_base="$tmp/core-base.yaml"
{
  doc Repository ksail
  doc ConfigMap settings "flux-system" "v1"
} >"$core_base"
core_head="$tmp/core-head.yaml"
doc Repository ksail >"$core_head"
run_case 1 "a core-group identity is spelled without a group" \
  "$core_base" "$core_head" "$tmp/body-empty.txt" "Deletion-Acknowledged: ConfigMap/flux-system/settings"
printf 'Deletion-Acknowledged: ConfigMap/flux-system/settings\n' >"$tmp/body-core.txt"
run_case 0 "the core-group acknowledgement passes" "$core_base" "$core_head" "$tmp/body-core.txt"

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
  "$full" "$minus_ns_label" "$tmp/body-empty.txt" "Deletion-Acknowledged: $ns_label_id"
printf 'Deletion-Acknowledged: Label.%s/ksail-bug\n' "$group" >"$tmp/body-wrong-twin.txt"
run_case 1 "acknowledging the cluster-scoped twin does not cover the namespaced one" \
  "$full" "$minus_ns_label" "$tmp/body-wrong-twin.txt" "Deletion-Acknowledged: $ns_label_id" "does not remove"
printf 'Deletion-Acknowledged: %s\n' "$ns_label_id" >"$tmp/body-ns.txt"
run_case 0 "the namespaced acknowledgement passes" "$full" "$minus_ns_label" "$tmp/body-ns.txt"

# Several removals need several lines; a partial acknowledgement still fails and
# names only what is missing.
minus_two="$tmp/minus-two.yaml"
{
  doc Repository ksail
  doc Label "ksail-bug"
} >"$minus_two"
run_case 1 "a partial acknowledgement fails on the remaining identity" \
  "$full" "$minus_two" "$tmp/body-ack.txt" "Deletion-Acknowledged: $ns_label_id"
assert_absent "partial acknowledgement re-lists an acknowledged identity" \
  "$full" "$minus_two" "$tmp/body-ack.txt" "Deletion-Acknowledged: $repo_id"
printf 'Deletion-Acknowledged: %s\nDeletion-Acknowledged: %s\n' "$repo_id" "$ns_label_id" >"$tmp/body-two.txt"
run_case 0 "acknowledging every removal passes" "$full" "$minus_two" "$tmp/body-two.txt" "2 removed resource(s)"

# --- Stale acknowledgement -----------------------------------------------------
run_case 1 "an acknowledgement for a resource still present fails" \
  "$full" "$same" "$tmp/body-ack.txt" "does not remove" "$repo_id"

# --- Fail-closed: exit 2, never a pass --------------------------------------------
: >"$tmp/empty.yaml"
run_case 2 "an empty head render is UNKNOWN, not a mass deletion" "$full" "$tmp/empty.yaml" "$tmp/body-empty.txt" "renders no documents"
run_case 2 "an empty base render is UNKNOWN, not a clean pass" "$tmp/empty.yaml" "$full" "$tmp/body-empty.txt" "renders no documents"
{
  doc Repository ksail
  printf -- '---\napiVersion: v1\nkind: Label\nmetadata:\n  labels:\n    x: y\n'
} >"$tmp/nameless.yaml"
run_case 2 "a nameless document in the head render is UNKNOWN" "$full" "$tmp/nameless.yaml" "$tmp/body-empty.txt" "no kind or no metadata.name"
run_case 2 "a nameless document in the base render is UNKNOWN" "$tmp/nameless.yaml" "$full" "$tmp/body-empty.txt" "no kind or no metadata.name"
{
  doc Repository ksail
  printf -- '---\napiVersion: v1\nmetadata:\n  name: kindless\n'
} >"$tmp/kindless.yaml"
run_case 2 "a kindless document is UNKNOWN" "$full" "$tmp/kindless.yaml" "$tmp/body-empty.txt" "no kind or no metadata.name"
run_case 2 "a missing body file is UNKNOWN" "$full" "$same" "$tmp/does-not-exist.txt" "not a readable file"
rc=0
bash "$validator" "$full" "$same" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "missing arguments: expected exit 2, got $rc"

# Missing yq must be exit 2, not a pass. A PATH holding only the coreutils the
# validator needs (and no yq) proves the guard does not silently continue.
bin="$tmp/bin"
mkdir -p "$bin"
for t in bash sort comm sed tr wc cat printf awk; do
  p="$(command -v "$t")" && ln -s "$p" "$bin/$t" || true
done
rc=0
PATH="$bin" bash "$validator" "$full" "$same" "$tmp/body-empty.txt" >/dev/null 2>"$tmp/err-noyq" || rc=$?
[[ "$rc" == 2 ]] || fail "missing yq: expected exit 2, got $rc ($(cat "$tmp/err-noyq"))"
grep -qF 'yq is required' "$tmp/err-noyq" || fail "missing yq: expected the message to name yq"
# The same holds for every other command the validator relies on: with yq present
# but awk missing, the guard must still exit 2 and name the missing tool.
bin2="$tmp/bin2"
mkdir -p "$bin2"
for t in bash sort comm sed tr wc cat printf yq; do
  p="$(command -v "$t")" && ln -s "$p" "$bin2/$t" || true
done
rc=0
PATH="$bin2" bash "$validator" "$full" "$same" "$tmp/body-empty.txt" >/dev/null 2>"$tmp/err-noawk" || rc=$?
[[ "$rc" == 2 ]] || fail "missing awk: expected exit 2, got $rc ($(cat "$tmp/err-noawk"))"
grep -qF 'awk is required' "$tmp/err-noawk" || fail "missing awk: expected the message to name awk"

# --- Negative control: the guard actually evaluates the renders it is given ------
# Feed the SAME file as base and head where a deletion was expected: the case
# must now PASS, proving the earlier failure came from the diff and not from the
# body alone.
run_case 0 "negative control: identical renders pass even with an empty body" "$minus_repo" "$minus_repo" "$tmp/body-empty.txt"

echo "deploy-deletions test: OK"
