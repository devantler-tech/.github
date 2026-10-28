#!/usr/bin/env bash

# Every automated commit this org's shared workflows produce must be signed.
#
# Unsigned automation commits are not broken today — what lands on a default branch is a
# GitHub-created squash commit, which is signed regardless. The cost is optionality:
# commit-signature verification cannot be REQUIRED on branches while any write lane would
# be refused by it, so the strongest form of that control stays permanently out of reach
# (devantler-tech/.github#142).
#
# The current signing API producer and legacy action mechanisms are checked differently:
#
#   * `apply-signed-fixes.yaml` creates a commit through GitHub's API and verifies its
#     signature before promotion. When the last create-pull-request action is retired,
#     its existing caller/callee signing guard supplies the positive producer control.
#     Legacy action checks below still reject unsafe reintroduction.
#
#   * `peter-evans/create-pull-request` commits locally by default. Its `sign-commits: true`
#     option makes it commit through the GitHub API instead, and GitHub signs a commit an
#     App or Actions token creates when the request carries no custom author/committer or
#     signature fields.
#     `sign-commits: true` alone is not sufficient: GitHub signs the commit only when the
#     request carries a token it will sign for — the default GITHUB_TOKEN, or a GitHub App
#     token. With a PAT the action still opens the PR and still reports success while the
#     commit lands unsigned, so the option is checked together with its token source.
#   * `stefanzweifel/git-auto-commit-action` has no such option — it can only run a local
#     `git commit`, so its output is unsigned unless a signing key is configured on the
#     runner. The fixer lanes migrated off it (#1005, #1011, #1036) onto the shared
#     `apply-signed-fixes.yaml`; this test keeps them off it.

# SCOPE: reusable workflows only. Verified when this test was written that no composite
# action or script in this repository produces a commit, so `.github/workflows` is the
# complete set of producers. If a composite action ever commits, widen this scan — the
# assertions below cannot see outside `workflow_dir`.

set -euo pipefail

workflow_dir="${1:-.github/workflows}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -d "$workflow_dir" ]] || fail "workflow directory '$workflow_dir' does not exist"
command -v yq >/dev/null || fail "yq is unavailable"
command -v jq >/dev/null || fail "jq is unavailable"

cpr_total=0
cpr_unsigned=()
cpr_signed=0
cpr_bad_token=()
auto_commit=()
api_signed=0

# NOTE: a `while read` loop in a pipeline runs in a subshell under some shells, losing every
# variable it sets — collect the file list first and feed it in on stdin instead.
workflows=()
while IFS= read -r wf; do
  [[ -n "$wf" ]] || continue
  workflows+=("$wf")
done <<<"$(find "$workflow_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"
((${#workflows[@]} > 0)) || fail "no workflow files found under '$workflow_dir'"

for wf in "${workflows[@]}"; do
  count="$(
    yq -r '[.jobs[]?.steps[]? | select((.uses // "") | test("^peter-evans/create-pull-request@"))] | length' "$wf"
  )" || fail "could not parse '$wf'"
  cpr_total=$((cpr_total + count))

  if [[ "$count" != "0" ]]; then
    unsigned="$(
      yq -r '
        [.jobs[]?.steps[]?
         | select((.uses // "") | test("^peter-evans/create-pull-request@"))
         | select((.with."sign-commits" // false) != true)
         | (.name // .id // .uses)]
        | .[]' "$wf"
    )" || fail "could not parse '$wf'"
    while IFS= read -r step; do
      [[ -n "$step" ]] || continue
      cpr_unsigned+=("$wf :: $step")
    done <<<"$unsigned"

    # `sign-commits: true` only signs when the token GitHub commits with is one GitHub will
    # sign for: the default GITHUB_TOKEN, or an App token. With a PAT the action still opens
    # the PR and still reports success, but the commit lands UNSIGNED — so the assertion above
    # passes on exactly the configuration it exists to catch. Resolve each signed step's token
    # back to its source and reject anything that is not signing-capable.
    signed_count="$(
      yq -r '[.jobs[]?.steps[]?
             | select((.uses // "") | test("^peter-evans/create-pull-request@"))
             | select((.with."sign-commits" // false) == true)] | length' "$wf"
    )" || fail "could not parse '$wf'"
    cpr_signed=$((cpr_signed + signed_count))

    badtoken="$(
      yq -o=json '.' "$wf" | jq -r '
        # WHITELIST, not a blacklist: rather than hunting for disapproved reference spellings,
        # subtract every APPROVED reference from the expression and require nothing to remain.
        # Extracting only recognised fragments let an unrecognised spelling ride alongside an
        # approved one -- `${{ github.token || github.event.inputs['"'"'token'"'"'] }}` scanned as
        # "github.token, all approved". Anything this cannot account for is unproven, so it fails.
        def approved($id): "steps\\." + $id + "\\.outputs\\.[A-Za-z0-9_-]+";
        def residue($e; $appIds):
          (reduce $appIds[] as $id ($e; gsub(approved($id); " ")))
          | gsub("secrets\\.GITHUB_TOKEN"; " ")
          | gsub("github\\.token"; " ")
          | gsub("\\|\\|"; " ")
          | gsub("\\s"; "");
        (.jobs // {}) | to_entries[]
        | (.value.steps // []) as $steps
        # A step id is trusted only when it is BOTH an App-token step and a plain identifier --
        # an exotic id would otherwise be interpolated straight into the regex above.
        | ([$steps[]
            | select((.uses // "") | startswith("actions/create-github-app-token@"))
            | .id | select(type == "string" and test("^[A-Za-z0-9_-]+$"))]) as $appIds
        | $steps[]
        | select((.uses // "") | startswith("peter-evans/create-pull-request@"))
        | select(((.with // {})."sign-commits" // false) == true)
        | . as $s
        | (($s.name // $s.id // $s.uses)) as $label
        | ("token", "branch-token") as $key
        | (($s.with // {})[$key] // null) as $val
        | select($val != null)
        | ($val | tostring) as $expr
        | ([$expr | scan("\\$\\{\\{([^}]*)\\}\\}")] | map(.[0])) as $inner
        # Text outside every ${{ }} must be whitespace: a literal, or a token glued onto an
        # interpolation, is not a reference this can vet.
        | ($expr | gsub("\\$\\{\\{[^}]*\\}\\}"; "") | gsub("\\s"; "")) as $outside
        | select(($inner | length) == 0
                 or ($outside | length) > 0
                 or ([$inner[] | select(residue(.; $appIds) != "")] | length) > 0)
        | "\($label) :: \($key): \($expr)"
'
    )" || fail "could not resolve token sources in '$wf'"
    while IFS= read -r step; do
      [[ -n "$step" ]] || continue
      cpr_bad_token+=("$wf :: $step")
    done <<<"$badtoken"
  fi

  gac="$(
    yq -r '[.jobs[]?.steps[]? | select((.uses // "") | test("^stefanzweifel/git-auto-commit-action@"))] | length' "$wf"
  )" || fail "could not parse '$wf'"
  [[ "$gac" == "0" ]] || auto_commit+=("$wf ($gac step(s))")
done

# A real producer must be examined even after all legacy action calls leave the
# catalogue. Reuse the current caller/callee guard: it requires actual delegation,
# the signing API mutation, runtime signature verification and the audited execution
# boundary. A missing producer or a diagnostics-only mutation still fails closed.
if ((cpr_total == 0)); then
  workflow_dir_abs="$(cd "$workflow_dir" && pwd)"
  api_root="$(cd "$workflow_dir_abs/../.." && pwd)"
  [[ "$workflow_dir_abs" == "$api_root/.github/workflows" ]] ||
    fail "no recognized signing producer under '$workflow_dir'"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "$api_root" && bash "$here/test-lint-signed-commit.sh") ||
    fail 'the retained signing API producer did not pass its caller/callee guard'
  api_signed=1
fi

if ((${#cpr_unsigned[@]} > 0)); then
  printf 'FAIL: these create-pull-request steps commit locally and produce UNSIGNED commits.\n' >&2
  printf '      Add sign-commits: true so the commit is made through the GitHub API and signed:\n' >&2
  printf '        - %s\n' "${cpr_unsigned[@]}" >&2
  exit 1
fi

# Second positive control, for the token-source assertion specifically. cpr_total > 0 does not
# cover it: every step could carry sign-commits: false, in which case the token check silently
# examines nothing. It sits AFTER the unsigned check so a workflow that simply forgot the option
# gets that check's actionable message rather than this one.
((cpr_total == 0 || cpr_signed > 0)) ||
  fail "no create-pull-request step under '$workflow_dir' sets sign-commits: true — the token-source assertion would pass vacuously"

if ((${#cpr_bad_token[@]} > 0)); then
  printf 'FAIL: these create-pull-request steps set sign-commits: true but commit with a token\n' >&2
  printf '      GitHub will not sign for, so their commits land UNSIGNED anyway. Use the default\n' >&2
  printf '      GITHUB_TOKEN or an actions/create-github-app-token output:\n' >&2
  printf '        - %s\n' "${cpr_bad_token[@]}" >&2
  exit 1
fi

if ((${#auto_commit[@]} > 0)); then
  printf 'FAIL: git-auto-commit-action cannot produce a signed commit; use the shared\n' >&2
  printf '      apply-signed-fixes.yaml workflow instead:\n' >&2
  printf '        - %s\n' "${auto_commit[@]}" >&2
  exit 1
fi

echo "PASS: $api_signed signing API producer(s) verified; all $cpr_total create-pull-request step(s) sign their commits ($cpr_signed via a signing-capable token), and no workflow commits with git-auto-commit-action"
