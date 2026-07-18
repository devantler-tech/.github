#!/usr/bin/env bash
#
# Guards the *completeness* of the declarative model in deploy/.
#
# Every repository the org manages should appear in every deploy/ dimension.
# When a repo is created or renamed it is typically added to one or two
# dimensions and quietly missed in the rest, leaving it partly declared: it
# looks managed on inspection while un-modelled settings drift underneath.
#
# This test is hermetic — it reads only the repository tree, never the GitHub
# API (CI runs with `permissions: {}` and no token). The expected repository set
# is therefore the UNION of the repos named across all dimensions, which is
# exactly the drift class we care about: a repo present in some dimensions and
# absent from others. See KNOWN LIMITATION at the bottom.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "declarative-coverage test: $*" >&2
  exit 1
}

# Dimensions, as "<label>:<glob-dir>:<prefix>". A repo is "declared" in a
# dimension when a file named <prefix><repo>.yaml exists in <glob-dir>.
dimensions=(
  "repositories:deploy/repositories:"
  "repository-permissions:deploy/repository-permissions:"
  "labels:deploy/labels:"
  "team-admins:deploy/team-repositories:grant-admins-on-"
  "team-maintainers:deploy/team-repositories:grant-maintainers-on-"
)

# Deliberate omissions. Each entry is "<dimension>/<repo>  # reason".
# An exemption is DECLARED INTENT — it keeps a known gap visible and reviewable
# instead of silently absent. Prune entries as gaps close; never add one to
# silence a fresh failure without a tracked reason.
exemptions=(
  # Tracked in devantler-tech/.github#114 — pre-existing gaps found when this
  # guard was introduced. Exempted so the guard can land green and ratchet:
  # it fails on any NEW drift while these are closed separately.
  "repositories/actions"
  "repositories/dot-github"
  "repositories/monorepo"
  "repository-permissions/aws"
  "repository-permissions/kyverno-policies"
  "repository-permissions/monorepo"
  "repository-permissions/provider-upjet-unifi"
  "team-maintainers/agent-plugins"
  "team-maintainers/agent-skills"
  "team-maintainers/ascoachingogvaner"
  "team-maintainers/dot-github"
  "team-maintainers/fleet-gitops"
  "team-maintainers/maintenance"
  "team-maintainers/wedding-app"
)

is_exempt() {
  local needle="$1" entry
  for entry in "${exemptions[@]}"; do
    [[ "$entry" == "$needle" ]] && return 0
  done
  return 1
}

# --- Collect the declared repos per dimension --------------------------------
declared_all=""
dimension_repos_file="$(mktemp -d)"
trap 'rm -rf "$dimension_repos_file"' EXIT

for spec in "${dimensions[@]}"; do
  IFS=':' read -r label dir prefix <<<"$spec"
  [[ -d "$repo_root/$dir" ]] || fail "dimension '$label': missing directory $dir"

  # Enumerate with find (not a bare glob) so an enumeration FAILURE is visible
  # rather than collapsing into an empty-and-therefore-passing set.
  if ! found="$(find "$repo_root/$dir" -maxdepth 1 -type f -name "${prefix}*.yaml" -print)"; then
    fail "dimension '$label': enumeration of $dir failed"
  fi

  repos="$(printf '%s\n' "$found" |
    sed -e "s|.*/${prefix}||" -e 's|\.yaml$||' |
    grep -v '^kustomization$' |
    grep -v '^$' |
    sort -u || true)"

  # A dimension that yields nothing is a broken selector, never "nothing to do".
  [[ -n "$repos" ]] || fail "dimension '$label': no repositories found in $dir (broken selector?)"

  printf '%s\n' "$repos" >"$dimension_repos_file/$label"
  declared_all="$(printf '%s\n%s\n' "$declared_all" "$repos")"
done

expected="$(printf '%s\n' "$declared_all" | grep -v '^$' | sort -u)"
expected_count="$(printf '%s\n' "$expected" | wc -l | tr -d ' ')"

# The union must be non-trivial; a collapsed set would make every check vacuous.
[[ "$expected_count" -ge 10 ]] ||
  fail "expected repository set collapsed to $expected_count entries — refusing to run vacuously"

# --- Compare every dimension against the union -------------------------------
missing_report=""
missing_count=0
exempt_count=0

while IFS= read -r label_file; do
  label="$(basename "$label_file")"
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if ! grep -Fxq "$repo" "$label_file"; then
      if is_exempt "$label/$repo"; then
        exempt_count=$((exempt_count + 1))
      else
        missing_report="${missing_report}  - ${label}: ${repo}"$'\n'
        missing_count=$((missing_count + 1))
      fi
    fi
  done <<<"$expected"
done < <(find "$dimension_repos_file" -maxdepth 1 -type f -print)

# --- Verify every exemption is still real ------------------------------------
# A stale exemption is as bad as a missing check: it hides the ratchet slipping
# backwards. If a gap has been closed, the exemption must be removed.
stale_report=""
for entry in "${exemptions[@]}"; do
  label="${entry%%/*}"
  repo="${entry#*/}"
  entry_file="$dimension_repos_file/$label"
  [[ -f "$entry_file" ]] || fail "exemption '$entry' names unknown dimension '$label'"
  if grep -Fxq "$repo" "$entry_file"; then
    stale_report="${stale_report}  - ${label}: ${repo}"$'\n'
  fi
done

if [[ -n "$stale_report" ]]; then
  echo "declarative-coverage test: these exemptions are STALE — the gap is closed," >&2
  echo "so remove them from tests/declarative-coverage.sh:" >&2
  printf '%s' "$stale_report" >&2
  exit 1
fi

if [[ "$missing_count" -gt 0 ]]; then
  echo "declarative-coverage test: $missing_count repository/dimension pair(s) are not declared" >&2
  echo "in deploy/. Add the missing manifest, or add an exemption with a tracked reason:" >&2
  printf '%s' "$missing_report" >&2
  exit 1
fi

echo "declarative-coverage: OK — $expected_count repositories across ${#dimensions[@]} dimensions" \
  "($exempt_count declared exemption(s))"

# KNOWN LIMITATION: because the expected set is derived from the tree, a
# repository absent from EVERY dimension is invisible to this guard. Closing
# that needs a live org listing (an API token in CI); tracked separately.
