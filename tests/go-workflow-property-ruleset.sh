#!/usr/bin/env bash
# The opted-in Go projects ruleset (platform#5852) must require exactly the
# language rule's workflow and policy, select only AlwaysValidateGoProject=true,
# exclude exactly the repositories the language rule already selects, and never
# hold Delete authority.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  printf 'go-workflow-property-ruleset: %s\n' "$*" >&2
  return 1
}
# Compare the opt-in rule in the render at $1 with the language rule beside it.
check_rule() {
  local rendered
  rendered="$(yq -o=json -I=0 '.' "$1" | jq -s '.')" || {
    fail 'unreadable render'
    return 1
  }
  # Print the name of every assertion that does not hold; none printed means the policy matches.
  local failed
  failed="$(jq -r '
    [.[] | select(.kind == "OrganizationRuleset" and .metadata.name == "require-workflows-go")] as $language |
    [.[] | select(.kind == "OrganizationRuleset" and
      (.metadata.name == "require-workflows-go-by-property" or
        .spec.forProvider.name == "Require workflows to pass before merging for opted-in Go projects"))] as $opt_in |
    if ($language | length) != 1 then "one language rule"
    elif ($opt_in | length) != 1 then "one opt-in rule"
    else
      $language[0].spec.forProvider as $l |
      $opt_in[0] as $r |
      ($r.spec.forProvider // {}) as $p |
      ($p.conditions[0] // {}) as $c |
      try (
        [
          ["apiVersion", $r.apiVersion == "enterprise.github.m.upbound.io/v1alpha1"],
          ["name", $r.metadata.name == "require-workflows-go-by-property"],
          ["cluster scope", ($r.metadata | has("namespace") | not)],
          ["no external name", (($r.metadata.annotations // {})["crossplane.io/external-name"] // "") == ""],
          ["management policies", $r.spec.managementPolicies == ["Observe", "Create", "Update", "LateInitialize"]],
          ["provider config", $r.spec.providerConfigRef == {kind: "ProviderConfig", name: "default"}],
          ["spec fields", ($r.spec | keys) == ["forProvider", "managementPolicies", "providerConfigRef"]],
          ["forProvider fields", ($p | keys) == ["bypassActors", "conditions", "enforcement", "name", "rules", "target"]],
          ["ruleset name", $p.name == "Require workflows to pass before merging for opted-in Go projects"],
          ["target", $p.target == $l.target],
          ["active", $p.enforcement == "active" and $p.enforcement == $l.enforcement],
          ["bypass parity", $p.bypassActors == $l.bypassActors],
          ["rules parity", $p.rules == $l.rules],
          ["one condition", ($p.conditions | length) == 1],
          ["condition fields", ($c | keys) == ["refName", "repositoryProperty"]],
          ["ref parity", $c.refName == $l.conditions[0].refName],
          ["one property selector", ($c.repositoryProperty | length) == 1],
          ["opt-in selector", $c.repositoryProperty[0].include ==
            [{name: "AlwaysValidateGoProject", propertyValues: ["true"], source: "custom"}]],
          ["language exclusion", $c.repositoryProperty[0].exclude == $l.conditions[0].repositoryProperty[0].include],
          ["language selector", $l.conditions[0].repositoryProperty[0].include ==
            [{name: "language", propertyValues: ["Go"], source: "system"}]]
        ] | .[] | select(.[1] != true) | .[0]
      ) catch "unevaluable policy (\(.))"
    end
  ' <<<"$rendered")" || {
    fail 'unreadable render'
    return 1
  }
  [[ -z "$failed" ]] || {
    fail "unexpected opted-in Go projects policy: ${failed//$'\n'/, }"
    return 1
  }
}
# Only platform opts in; every other repository follows its detected language.
check_values() {
  local opted
  opted="$(yq -N 'select(.kind == "RepositoryCustomProperty" and .spec.forProvider.propertyName == "AlwaysValidateGoProject" and (.spec.forProvider.propertyValue | length) == 1 and .spec.forProvider.propertyValue[0] == "true") | .spec.forProvider.repository' "$1")" || {
    fail 'unreadable property values'
    return 1
  }
  [[ "$opted" == platform ]] || {
    fail "unexpected opted-in repositories: ${opted:-none}"
    return 1
  }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || {
    fail 'unreadable CI'
    return 1
  }
  jq -e '[.[] | select(.run == "bash tests/go-workflow-property-ruleset.sh")]
    | length == 1 and (.[0] | has("if") | not)
      and (.[0] | has("continue-on-error") | not)' <<<"$steps" >/dev/null || {
    fail 'missing unconditional CI guard'
    return 1
  }
}
kubectl kustomize "$root/deploy" >"$work/render.yaml" || {
  fail 'render failed'
  exit 1
}
check_rule "$work/render.yaml"
check_values "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
selector='select(.kind == "OrganizationRuleset" and .metadata.name == "require-workflows-go-by-property")'
mutations=(
  '.spec.managementPolicies += ["Delete"]'
  '.spec.managementPolicies = ["*"]'
  '.spec.managementPolicies = ["Observe"]'
  '.metadata.annotations."crossplane.io/external-name" = "10320335"'
  '.metadata.namespace = "another-namespace"'
  '.spec.forProvider.enforcement = "disabled"'
  '.spec.forProvider.enforcement = "evaluate"'
  '.spec.forProvider.target = "tag"'
  '.spec.forProvider.bypassActors = []'
  '.spec.forProvider.bypassActors += [{"actorId":123,"actorType":"Integration","bypassMode":"always"}]'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path = ".github/workflows/other.yaml"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref = "refs/heads/other"'
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId = 948529001'
  '.spec.forProvider.rules[0].requiredWorkflows[0].doNotEnforceOnCreate = false'
  'del(.spec.forProvider.rules[0].requiredWorkflows)'
  '.spec.forProvider.conditions[0].refName[0].include = ["~ALL"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].propertyValues = ["false"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].propertyValues = ["true", "false"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].name = "ScanGitHubActions"'
  '.spec.forProvider.conditions[0].repositoryProperty[0].include[0].source = "system"'
  'del(.spec.forProvider.conditions[0].repositoryProperty[0].exclude)'
  '.spec.forProvider.conditions[0].repositoryProperty[0].exclude[0].propertyValues = ["Rust"]'
  '.spec.forProvider.conditions[0].repositoryProperty[0].exclude[0].source = "custom"'
  'del(.spec.forProvider.conditions[0].repositoryProperty)'
  '.spec.forProvider.conditions[0].repositoryName = [{"include":["~ALL"],"exclude":[]}]'
  '.spec.initProvider = {"enforcement":"disabled"}'
  '.spec.providerConfigRef.name = "another-provider"'
)
for mutation in "${mutations[@]}"; do
  yq "($selector) |= ($mutation)" "$work/render.yaml" >"$work/bad.yaml"
  if check_rule "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
    fail "accepted mutation $mutation"
    exit 1
  fi
  grep -qF 'unexpected opted-in Go projects policy' "$work/diagnostic"
done
# A second copy of the rule, or none at all, is not the reviewed policy.
for control in "[$selector | .metadata.name = \"duplicate-go-opt-in\"] + [.] | .[]" "del($selector)"; do
  yq "$control" "$work/render.yaml" >"$work/bad.yaml"
  if check_rule "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
    fail "accepted control $control"
    exit 1
  fi
  grep -qF 'unexpected opted-in Go projects policy' "$work/diagnostic"
done
# Opting in another repository, or dropping platform, is a reviewed decision.
value_selector='select(.kind == "RepositoryCustomProperty" and .spec.forProvider.propertyName == "AlwaysValidateGoProject")'
for control in \
  "($value_selector | select(.spec.forProvider.repository == \"ksail\")).spec.forProvider.propertyValue = [\"true\"]" \
  "($value_selector | select(.spec.forProvider.repository == \"platform\")).spec.forProvider.propertyValue = [\"false\"]"; do
  yq "$control" "$work/render.yaml" >"$work/bad.yaml"
  if check_values "$work/bad.yaml" >"$work/diagnostic" 2>&1; then
    fail "accepted value control $control"
    exit 1
  fi
  grep -qF 'unexpected opted-in repositories' "$work/diagnostic"
done
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-property-ruleset.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-property-ruleset.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/go-workflow-property-ruleset.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" >"$work/ci.yaml"
  if check_ci "$work/ci.yaml" >"$work/diagnostic" 2>&1; then
    fail 'accepted weakened CI guard'
    exit 1
  fi
  grep -qF 'missing unconditional CI guard' "$work/diagnostic"
done
printf 'go-workflow-property-ruleset: PASS; opt-in rule mirrors the language rule; %s rejection controls\n' "$((${#mutations[@]} + 7))"
