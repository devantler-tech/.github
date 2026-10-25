#!/usr/bin/env bash
# #747: native issue types replace classification labels; retain independent labels.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

required='{"blocked":"d93f0b","released":"ededed","next":"5d3fd3","help wanted":"008672","good first issue":"7057ff","question":"d876e3","duplicate":"cfd3d7","wontfix":"ffffff","spam":"e4e669","off topic":"e4e669","needs triage":"fbca04","needs investigation":"fbca04","breaking change":"b60205","automation":"bfdadc","repo-assist":"bfdadc"}'
retired='["roadmap","bug","enhancement","documentation","performance","security","refactor"]'

check_taxonomy() {
  local input=$1
  jq -e '
    type == "array" and length > 0 and
    ([.[].spec.forProvider.repository] | length == (unique | length)) and
    all(.[]; .kind == "IssueLabels" and
      (.spec.forProvider.repository | type == "string" and length > 0) and
      (.spec.forProvider.label | type == "array" and length > 0 and
        all(.[]; (.name | type == "string" and length > 0) and
          (.color | type == "string" and test("^[a-fA-F0-9]{6}$"))) and
        ([.[].name] | length == (unique | length))))
  ' "$input" >/dev/null || {
    echo 'incomplete or ambiguous rendered label inventory'
    return 1
  }

  jq -e --argjson retired "$retired" '
    all(.[]; .spec.forProvider.label as $labels |
      all($retired[]; . as $name | all($labels[]; (.name | ascii_downcase) != $name)))
  ' "$input" >/dev/null || {
    echo 'duplicate issue-type labels remain in rendered set'
    return 1
  }

  jq -e --argjson required "$required" '
    all(.[]; .spec.forProvider.label as $labels |
      all($required | to_entries[]; . as $expected |
        any($labels[]; .name == $expected.key and .color == $expected.value)))
  ' "$input" >/dev/null || {
    echo 'cross-cutting label or its color was lost'
    return 1
  }
}

kubectl kustomize "$repo_root/deploy/labels" >"$work/render.yaml"
yq eval-all -o=json -I=0 '[select(.kind == "IssueLabels")]' "$work/render.yaml" >"$work/labels.json"
check_taxonomy "$work/labels.json"

# Test the actual rendered resources, then prove each refusal on its own mutation.
expect_refusal() {
  local filter=$1 expected=$2
  jq "$filter" "$work/labels.json" >"$work/mutant.json"
  if check_taxonomy "$work/mutant.json" >"$work/result"; then
    echo 'taxonomy mutation unexpectedly passed' >&2
    exit 1
  fi
  grep -Fxq "$expected" "$work/result" || {
    echo 'taxonomy mutation failed for the wrong reason' >&2
    exit 1
  }
}

expect_refusal '.[0].spec.forProvider.label += [{name:"bug",color:"d73a4a"}]' \
  'duplicate issue-type labels remain in rendered set'
expect_refusal '.[0].spec.forProvider.label |= map(select(.name != "blocked"))' \
  'cross-cutting label or its color was lost'
expect_refusal '.[0].spec.forProvider.label |= map(if .name == "automation" then .color = "000000" else . end)' \
  'cross-cutting label or its color was lost'
expect_refusal '.[0].spec.forProvider.label += [.[0].spec.forProvider.label[0]]' \
  'incomplete or ambiguous rendered label inventory'
expect_refusal '.[0].spec.forProvider.label = null' \
  'incomplete or ambiguous rendered label inventory'
expect_refusal '[]' 'incomplete or ambiguous rendered label inventory'

printf 'issue label taxonomy: PASS (%s rendered repositories; six mutation controls)\n' \
  "$(jq length "$work/labels.json")"
