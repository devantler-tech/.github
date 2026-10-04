#!/usr/bin/env bash
# Reject configuration/command regressions using the actual offline release suite.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$root/.github/tests/create-release-fixture.sh"
workflow="$root/.github/workflows/create-release.yaml"
config="$root/.releaserc"
mkdir -p "$work/template/hooks"
printf '#!/bin/sh\nexit 99\n' >"$work/template/hooks/pre-commit"
chmod +x "$work/template/hooks/pre-commit"
if ! env GIT_DIR="$work/foreign-git" GIT_WORK_TREE="$work/foreign-tree" GIT_INDEX_FILE="$work/foreign-index" \
  GIT_TEMPLATE_DIR="$work/template" GIT_CONFIG_PARAMETERS="'core.hooksPath'='$work/template/hooks'" \
  bash "$fixture" >"$work/output" 2>&1; then
  cat "$work/output" >&2
  echo 'FAIL: ambient Git overrides redirected fixture operations' >&2
  exit 1
fi
[[ ! -e "$work/foreign-git" && ! -e "$work/foreign-tree" && ! -e "$work/foreign-index" ]]
echo 'PASS: ambient Git paths, templates and hooks cannot redirect fixture operations'
reject() {
  local label="$1" workflow_path="$2" config_path="$3" diagnostic="$4"
  if bash "$fixture" "$workflow_path" "$config_path" >"$work/output" 2>&1; then
    echo "FAIL: $label was accepted" >&2
    exit 1
  fi
  grep -qF "$diagnostic" "$work/output" || {
    cat "$work/output" >&2
    exit 1
  }
  echo "PASS: rejected $label ($diagnostic)"
}
jq 'del(.plugins[0][1].parserOpts.breakingHeaderPattern)' "$config" >"$work/no-parser.json"
reject 'missing breaking parser' "$workflow" "$work/no-parser.json" 'FAIL: breaking expected 2.0.0'
jq '(.plugins[0][1].releaseRules[] | select(.breaking == true) | .release) = false' "$config" >"$work/no-major.json"
reject 'disabled major rule' "$workflow" "$work/no-major.json" 'FAIL: breaking expected 2.0.0'
jq '.plugins[0][1].releaseRules |= map(select(.type != "revert"))' "$config" >"$work/no-revert.json"
reject 'missing revert rule' "$workflow" "$work/no-revert.json" 'FAIL: revert expected 1.2.4'
yq '(.jobs.release.steps[] | select(.name == "🎉 Release") | .run) = "echo PASS"' "$workflow" >"$work/bypass.yaml"
reject 'release command bypass' "$work/bypass.yaml" "$config" 'unsupported shipped release command'
# The native warning fixture must execute the shipped guard and preserve dry-run decisions.
if ! WARN_MISSING_BREAKING_BANG=true bash "$fixture" >"$work/output" 2>&1; then
  cat "$work/output" >&2
  exit 1
fi
grep -qF 'PASS: warning-missing -> 1.2.4; warning=1; files and refs unchanged' "$work/output" || {
  echo 'FAIL: native offline decisions do not exercise the missing-pattern warning' >&2
  exit 1
}
yq '(.jobs.release.steps[] | select(.id == "breaking-bang-guard") | .run) = "echo PASS"' "$workflow" >"$work/no-guard.yaml"
if WARN_MISSING_BREAKING_BANG=true bash "$fixture" "$work/no-guard.yaml" "$config" >"$work/output" 2>&1; then
  echo 'FAIL: warning guard bypass was accepted' >&2
  exit 1
fi
grep -qF 'FAIL: warning-missing expected 1 warning(s)' "$work/output"
yq '(.jobs.release.steps[] | select(.id == "breaking-bang-guard") | .run) += "\necho mutated >> .releaserc\n"' "$workflow" >"$work/guard-write.yaml"
if WARN_MISSING_BREAKING_BANG=true bash "$fixture" "$work/guard-write.yaml" "$config" >"$work/output" 2>&1; then
  echo 'FAIL: warning guard file mutation was accepted' >&2
  exit 1
fi
grep -qF 'FAIL: fix warning guard changed consumer files' "$work/output"
if WARN_MISSING_BREAKING_BANG=invalid bash "$fixture" >"$work/output" 2>&1; then
  echo 'FAIL: malformed warning opt-in was accepted' >&2
  exit 1
fi
grep -qF 'invalid warning setting' "$work/output"
echo 'PASS: seven independent behavioral regressions rejected'
