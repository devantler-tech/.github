#!/usr/bin/env bash
# Resolve the shipped installer floor and prepare only its complete reviewed manifest.
set -euo pipefail
fail() { echo "::error::$*" >&2; exit 1; }
version=''
for declaration in actions/setup-agent-skills/action.yaml actions/update-agent-skills/action.yaml \
  .github/workflows/update-agent-skills.yaml; do
  if [[ "$declaration" == actions/* ]]; then
    current="$(yq -er '.inputs."gh-version".default' "$declaration")"
  else
    current="$(yq -er '.on.workflow_call.inputs."gh-version".default' "$declaration")"
  fi
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Installer defaults must be bare semantic versions'
  [[ -z "$version" || "$current" == "$version" ]] || fail 'Installer version defaults disagree'
  version="$current"
done
status="$(git status --porcelain)" || fail 'Could not establish source checkout status'
[[ -z "$status" ]] || fail 'Digest preparation requires a clean source checkout'
bash .scripts/refresh-gh-digests.sh "$version"
changed="$(git diff --name-only)"
[[ -z "$changed" || "$changed" == .scripts/gh-release-digests.tsv ]] || fail 'Refresh changed an unrelated path'
untracked="$(git ls-files --others --exclude-standard)" || fail 'Could not establish untracked-path absence'
[[ -z "$untracked" ]] || fail 'Refresh left untracked files'
awk -F'\t' -v version="$version" '
  $1 == version {
    if (NF != 4 || $2 !~ /^(linux|macOS)$/ || $3 !~ /^(amd64|arm64)$/ ||
        length($4) != 64 || $4 !~ /^[0-9a-f]+$/ || seen[$2 FS $3]++) exit 1
    count++
  }
  END { if (count != 4) exit 1 }
' .scripts/gh-release-digests.tsv || fail 'Refresh did not bind all four unique platform assets'
printf 'version=%s\n' "$version" >>"${GITHUB_OUTPUT:?}"
if [[ -n "$changed" ]]; then printf 'changed=true\n'; else printf 'changed=false\n'; fi >>"$GITHUB_OUTPUT"
