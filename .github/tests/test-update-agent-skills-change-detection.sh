#!/usr/bin/env bash
# Pins #266: update-agent-skills reports `changed=true` for ANY change inside an installed skill's
# directory, not only a change to its SKILL.md. An upstream update that touches only a bundled
# script, reference or template leaves SKILL.md byte-identical, and the workflow gates both its
# single-PR and per-skill PR paths on this output, so a SKILL.md-only check silently dropped it.
#
# Runs the action's update step EXTRACTED FROM action.yaml, never a transcription, with a stub `gh`
# that performs one scenario's edits where `gh skill update` would write. Each scenario asserts the
# exact `changed` value, so a no-op still has to report `false`.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
action_dir="$repo_root/actions/update-agent-skills"
step_name="🔄 Update skills"

fail() {
  echo "::error::$*"
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

script="$work/update-step.sh"
STEP="$step_name" yq -r '.runs.steps[] | select(.name == strenv(STEP)) | .run' \
  "$action_dir/action.yaml" >"$script"
[[ -s "$script" ]] || fail "action.yaml has no '$step_name' step to exercise"

# The stub stands in for `gh skill update --all --dir <root> ...`: it applies the scenario named in
# $SCENARIO to the skills under <root>, the directory the real command writes to.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2 $3 $4" == "skill update --all --dir" ]] || { echo "unexpected gh call: $*" >&2; exit 64; }
root="$5"
skill="$root/demo"
[[ -d "$skill" ]] || exit 0 # only the root holding the demo skill is edited
case "$SCENARIO" in
  noop) ;;
  skill-md) printf 'Updated guidance.\n' >>"$skill/SKILL.md" ;;
  aux-modified) printf '# updated upstream\n' >>"$skill/scripts/helper.sh" ;;
  aux-added) mkdir -p "$skill/templates" && printf 'new template\n' >"$skill/templates/new.md" ;;
  aux-removed) rm "$skill/references/guide.md" ;;
  aux-renamed) mv "$skill/references/guide.md" "$skill/references/renamed.md" ;;
  aux-exec-bit) chmod -x "$skill/scripts/helper.sh" ;;
  aux-symlink) ln -sfn renamed.md "$skill/references/latest.md" ;;
  same-bytes) cp "$skill/references/guide.md" "$skill/references/guide.tmp" && mv "$skill/references/guide.tmp" "$skill/references/guide.md" ;;
  skill-removed) rm -rf "$skill" ;;
  skill-added) mkdir -p "$root/added" && printf -- '---\nname: added\n---\nAdded skill.\n' >"$root/added/SKILL.md" ;;
  git-metadata) printf 'ref: refs/heads/other\n' >"$skill/.git/HEAD" ;;
  *) echo "unknown scenario $SCENARIO" >&2; exit 64 ;;
esac
echo "Updated demo"
EOF
chmod +x "$work/bin/gh"

new_skills() { # <dir> — two installed skills; `demo` bundles auxiliary files
  rm -rf "$1"
  mkdir -p "$1/demo/scripts" "$1/demo/references" "$1/other"
  printf -- '---\nname: demo\n---\nDemo skill.\n' >"$1/demo/SKILL.md"
  printf '#!/usr/bin/env bash\necho helper\n' >"$1/demo/scripts/helper.sh"
  chmod +x "$1/demo/scripts/helper.sh"
  printf 'A reference.\n' >"$1/demo/references/guide.md"
  ln -s guide.md "$1/demo/references/latest.md"
  # Repository state inside a skill directory, e.g. a vendored checkout, is not skill content.
  mkdir -p "$1/demo/.git"
  printf 'ref: refs/heads/main\n' >"$1/demo/.git/HEAD"
  printf -- '---\nname: other\n---\nOther skill.\n' >"$1/other/SKILL.md"
}

expect() { # <scenario> <true|false> — runs the update step and checks its `changed` output
  local skills="$work/skills" output="$work/github-output" got
  new_skills "$skills"
  : >"$output"
  # Composite steps with `shell: bash` run as `bash --noprofile --norc -eo pipefail {0}`.
  if ! PATH="$work/bin:$PATH" SCENARIO="$1" GITHUB_ACTION_PATH="$action_dir" \
    GITHUB_OUTPUT="$output" GH_TOKEN=stub-not-a-secret RETRY_MAX_ATTEMPTS=1 \
    INPUT_DIR="$skills" INPUT_DRY_RUN=false INPUT_UNPIN=false INPUT_MARK_INTERNAL=false \
    bash --noprofile --norc -eo pipefail "$script" >"$work/step.log" 2>&1; then
    fail "the update step failed in scenario $1: $(cat "$work/step.log")"
  fi
  got=$(sed -n 's/^changed=//p' "$output")
  [[ "$got" == "$2" ]] || fail "scenario $1: expected changed=$2, got changed=${got:-<unset>}"
  echo "ok   $1 -> changed=$2"
}

# A change confined to an auxiliary file is a change.
expect aux-modified true
expect aux-added true
expect aux-removed true
expect aux-renamed true
expect aux-exec-bit true
expect aux-symlink true
# A SKILL.md change is still a change, and so is a whole skill disappearing or appearing.
expect skill-md true
expect skill-removed true
expect skill-added true
# Nothing changed, a file rewritten with identical bytes, or only repository state moved: no change.
expect noop false
expect same-bytes false
expect git-metadata false
