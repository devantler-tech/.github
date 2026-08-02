#!/usr/bin/env bash

set -euo pipefail

title="${1:-}"
release_title='^(feat|fix|perf|revert)(\([[:alnum:]_.-]+\))?!?: .+'
breaking_title='^[a-z]+(\([[:alnum:]_.-]+\))?!: .+'
deploy_changed=false

[[ -n "$title" ]] || {
  echo "release-contract: pull-request title is required" >&2
  exit 1
}

while IFS= read -r path; do
  if [[ "$path" == deploy/* ]]; then
    deploy_changed=true
  fi
done

if [[ "$deploy_changed" == false ]]; then
  echo "release-contract: OK — no deploy/ artifact change"
  exit 0
fi

if [[ "$title" =~ $release_title || "$title" =~ $breaking_title ]]; then
  echo "release-contract: OK — deploy/ change has a release-driving title"
  exit 0
fi

echo "release-contract: deploy/ changes require a release-driving PR title (fix, feat, perf, revert, or a breaking ! type); got '$title'" >&2
exit 1
