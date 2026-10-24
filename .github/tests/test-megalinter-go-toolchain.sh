#!/usr/bin/env bash
# Bind the container compiler to the declared consumer toolchain. Native CI
# proves actual scanner analysis; this guard rejects selection substitutions.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
yq -o=json '.' "$root/.github/workflows/validate-go-project.yaml" >"$scratch/go.json"
yq -o=json '.' "$root/.github/workflows/validate-go-project-readonly.yaml" >"$scratch/readonly.json"
jq -s '{go:.[0],readonly:.[1]}' "$scratch/go.json" "$scratch/readonly.json" >"$scratch/actual.json"
cat >"$scratch/admit.jq" <<'JQ'
def setup: [.jobs.lint.steps[] | select(.id == "setup-go")];
def ml: [.jobs.lint.steps[] | select(.id == "ml")];
(.go | setup) as $go
| ($go | length) == 1
and ($go[0] | (has("if") | not) and .with["go-version-file"] == "${{ needs.changes.outputs.module-directory }}/go.mod")
and ($go[0].uses | test("^actions/setup-go@[0-9a-f]{40}$"))
and ($go[0].with | keys == ["cache","go-version-file"] and .cache == false)
and (.go | ml | length) == 1
and (.go | ml | .[0].env.GOTOOLCHAIN) == "go${{ steps.setup-go.outputs.go-version }}"
and (.readonly | setup) == $go
and (.readonly | ml | length) == 1
and (.readonly | ml | .[0].env.GOTOOLCHAIN) == (.go | ml | .[0].env.GOTOOLCHAIN)
and (.readonly.jobs.lint.steps | map(.id) | index("setup-go") < index("ml"))
and (.go.jobs.lint.steps | map(.id) | index("setup-go") < index("ml"))
JQ
# Accepts only the declared compiler bindings and ordering in the supplied workflow snapshot.
admit() { jq -e -f "$scratch/admit.jq" "$1" >/dev/null; }
if ! admit "$scratch/actual.json"; then
  echo 'TEST FAIL -- MegaLinter container does not use its declared setup-go compiler' >&2
  exit 1
fi
count=0
for mutation in \
  'del(.go.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)' \
  '(.go.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="local"' \
  '(.go.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="auto"' \
  '(.go.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="go1.26.8"' \
  '(.go.jobs.lint.steps[] | select(.id == "setup-go") | .id)="other-go"' \
  '(.go.jobs.lint.steps[] | select(.id == "setup-go") | .if)="false"' \
  '(.go.jobs.lint.steps[] | select(.id == "setup-go") | .with["go-version"])="1.26.3"' \
  '(.readonly.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="local"' \
  '(.readonly.jobs.lint.steps[] | select(.id == "setup-go") | .with["go-version"])="1.26.3"' \
  'del(.readonly.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)' \
  '(.readonly.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="auto"' \
  '(.readonly.jobs.lint.steps[] | select(.id == "ml") | .env.GOTOOLCHAIN)="go1.26.8"' \
  '(.readonly.jobs.lint.steps[] | select(.id == "setup-go") | .id)="other-go"' \
  '(.readonly.jobs.lint.steps[] | select(.id == "setup-go") | .if)="true"'; do
  jq "$mutation" "$scratch/actual.json" >"$scratch/mutant.json"
  if cmp -s "$scratch/actual.json" "$scratch/mutant.json" || admit "$scratch/mutant.json"; then
    echo "TEST FAIL -- compiler binding mutation was ineffective or admitted: $mutation" >&2
    exit 1
  fi
  count=$((count + 1))
done
echo "TEST PASS -- declared container Go compiler and $count rejected binding substitutions"
