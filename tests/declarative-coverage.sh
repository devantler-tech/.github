#!/usr/bin/env bash
#
# Guards the *completeness* of the declarative model in deploy/.
#
# Every repository the org manages should appear in every deploy/ dimension.
# When a repo is created or renamed it is typically added to one or two
# dimensions and quietly missed in the rest, leaving it partly declared: it
# looks managed on inspection while un-modelled settings drift underneath.
#
# Coverage is read from the RENDERED output of `kubectl kustomize deploy/`,
# never from the filenames on disk, because only rendered resources reconcile:
#   - a manifest not listed in its directory's kustomization.yaml renders to
#     nothing (repository-permissions/ is deliberately in that state today), and
#   - a renamed file whose forProvider still names the old repo would look
#     declared under a filename-based check while reconciling the old repo.
# Both are exactly the partial-rename / partial-add drift this guard exists to
# catch, so the rendered manifest is the only trustworthy source.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "declarative-coverage test: $*" >&2
  exit 1
}

for tool in kubectl yq; do
  command -v "$tool" >/dev/null || fail "required tool '$tool' not found"
done

render="$(mktemp)"
work="$(mktemp -d)"
trap 'rm -f "$render"; rm -rf "$work"' EXIT

kubectl kustomize "$repo_root/deploy" >"$render" ||
  fail "kubectl kustomize deploy/ failed"
[[ -s "$render" ]] || fail "rendered output is empty"

# Dimensions, as "<label>:<yq selector producing one repo name per line>".
# Each selector runs against the rendered multi-document stream.
dimensions=(
  'repositories:select(.kind=="Repository" and .spec.forProvider.archived!=true)|.spec.forProvider.name'
  'labels:select(.kind=="IssueLabels")|.spec.forProvider.repository'
  'team-admins:select(.kind=="TeamRepository" and .spec.forProvider.teamIdRef.name=="admins")|.spec.forProvider.repository'
  'team-maintainers:select(.kind=="TeamRepository" and .spec.forProvider.teamIdRef.name=="maintainers")|.spec.forProvider.repository'
)

# Deliberate omissions, as "<dimension>/<repo>".
# An exemption is DECLARED INTENT — it keeps a known gap visible and reviewable
# instead of silently absent. Prune entries as gaps close; never add one to
# silence a fresh failure without a tracked reason. The guard fails on a stale
# exemption, so this list cannot rot.
exemptions=(
  # Tracked in devantler-tech/.github#115 — pre-existing gaps found when this
  # guard was introduced. Exempted so the guard can land green and ratchet:
  # it fails on any NEW drift while these are closed separately.
  "repositories/actions"
  "repositories/.github"
  "repositories/monorepo"
  "team-maintainers/agent-plugins"
  "team-maintainers/agent-skills"
  "team-maintainers/ascoachingogvaner"
  "team-maintainers/.github"
  "team-maintainers/fleet-gitops"
  "team-maintainers/maintenance"
  "team-maintainers/wedding-app"
)

is_exempt() {
  local needle="$1" entry
  # "${arr[@]}" on an empty array is an unbound-variable error under `set -u` on
  # bash < 4.4. This list is meant to shrink to empty as gaps close, so that end
  # state has to work everywhere, not just on the CI runner.
  ((${#exemptions[@]} == 0)) && return 1
  for entry in "${exemptions[@]}"; do
    [[ "$entry" == "$needle" ]] && return 0
  done
  return 1
}

# --- Collect the declared repos per dimension --------------------------------
labels=()
for spec in "${dimensions[@]}"; do
  label="${spec%%:*}"
  selector="${spec#*:}"
  labels+=("$label")

  if ! repos="$(yq -N "$selector" "$render")"; then
    fail "dimension '$label': yq selector failed"
  fi

  # `yq -N` suppresses the --- separators that would otherwise be read back as
  # repository names; drop blanks and nulls defensively as well.
  repos="$(printf '%s\n' "$repos" | grep -vE '^$|^null$|^---$' | sort -u || true)"

  # A dimension that yields nothing is a broken selector, never "nothing to do".
  [[ -n "$repos" ]] || fail "dimension '$label': no repositories rendered (broken selector?)"

  printf '%s\n' "$repos" >"$work/$label"
done

expected="$(cat "$work"/* | sort -u)"
expected_count="$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"

# The union must be non-trivial; a collapsed set would make every check vacuous.
[[ "$expected_count" -ge 10 ]] ||
  fail "expected repository set collapsed to $expected_count entries — refusing to run vacuously"

# --- Compare every dimension against the union -------------------------------
missing_report=""
missing_count=0
exempt_count=0

for label in "${labels[@]}"; do
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if ! grep -Fxq "$repo" "$work/$label"; then
      if is_exempt "$label/$repo"; then
        exempt_count=$((exempt_count + 1))
      else
        missing_report="${missing_report}  - ${label}: ${repo}"$'\n'
        missing_count=$((missing_count + 1))
      fi
    fi
  done <<<"$expected"
done

# --- Verify every exemption is still real and still relevant -----------------
# Two ways an exemption goes stale: the gap was closed (the repo now IS declared
# in that dimension), or the repo left the model entirely (renamed/removed), in
# which case a dead entry could later mask a partial re-add of the same name.
stale_report=""
for entry in ${exemptions[@]+"${exemptions[@]}"}; do
  label="${entry%%/*}"
  repo="${entry#*/}"
  [[ -f "$work/$label" ]] || fail "exemption '$entry' names unknown dimension '$label'"
  if grep -Fxq "$repo" "$work/$label"; then
    stale_report="${stale_report}  - ${entry} — now declared; delete this exemption"$'\n'
  elif ! printf '%s\n' "$expected" | grep -Fxq "$repo"; then
    stale_report="${stale_report}  - ${entry} — repo is no longer in the model; delete this exemption"$'\n'
  fi
done

if [[ -n "$stale_report" ]]; then
  echo "declarative-coverage test: stale exemption(s) in tests/declarative-coverage.sh:" >&2
  printf '%s' "$stale_report" >&2
  exit 1
fi

if [[ "$missing_count" -gt 0 ]]; then
  echo "declarative-coverage test: $missing_count repository/dimension pair(s) are not declared" >&2
  echo "in the rendered deploy/ output. Add the missing manifest (and wire it into that" >&2
  echo "directory's kustomization.yaml), or add an exemption with a tracked reason:" >&2
  printf '%s' "$missing_report" >&2
  exit 1
fi

echo "declarative-coverage: OK — $expected_count repositories across ${#labels[@]} rendered" \
  "dimensions ($exempt_count declared exemption(s))"

# KNOWN LIMITATION: the expected set is the union of repos already present in the
# rendered model, so a repository absent from EVERY dimension is invisible here.
# Closing that needs a live org listing, and CI runs with `permissions: {}` and no
# token; tracked separately rather than bolted on.
