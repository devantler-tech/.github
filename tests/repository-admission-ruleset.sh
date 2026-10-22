#!/usr/bin/env bash
# Bind additive canary enforcement while the original trusted gate still runs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'repository admission policy: %s\n' "$*" >&2; exit 1; }
check_render() {
  jq -e '
    def managed: ["Observe","Create","Update","LateInitialize"];
    def branch: [{"refName":[{"include":["~DEFAULT_BRANCH"],"exclude":[]}]}];
    def provider: {kind:"ProviderConfig",name:"default"};
    def unique_policy($kind;$name;$display):
      [.[] | select(.kind==$kind and
        (.metadata.name==$name or .spec.forProvider.name==$display))];
    unique_policy("OrganizationRuleset";"require-repository-pr-admission";"Require workflow - Repository PR admission") as $org |
    unique_policy("RepositoryRuleset";"monorepo-require-reviewed-admission";"Require reviewed repository admission") as $repo |
    unique_policy("OrganizationRuleset";"require-monorepo-ci-aggregate-contract";"Require workflow - Monorepo CI aggregate contract") as $old |
    ($org|length)==1 and ($repo|length)==1 and ($old|length)==1 and
    $org[0].apiVersion=="enterprise.github.m.upbound.io/v1alpha1" and
    $org[0].spec=={
      managementPolicies:managed,
      forProvider:{
        name:"Require workflow - Repository PR admission",target:"branch",enforcement:"active",
        conditions:[{refName:[{include:["~DEFAULT_BRANCH"],exclude:[]}],repositoryId:[786274843]}],
        rules:[{requiredWorkflows:[{requiredWorkflow:[{
          repositoryId:933213756,path:".github/workflows/repository-pr-admission.yaml",ref:"refs/heads/main"
        }]}]}]
      },
      providerConfigRef:provider
    } and
    $repo[0].apiVersion=="repo.github.m.upbound.io/v1alpha1" and
    $repo[0].spec=={
      managementPolicies:managed,
      forProvider:{
        repository:"monorepo",name:"Require reviewed repository admission",target:"branch",enforcement:"active",
        conditions:branch,
        rules:[{requiredStatusChecks:[{
          requiredCheck:[{context:"Run reviewed product admission",integrationId:15368}],
          strictRequiredStatusChecksPolicy:false
        }]}]
      },
      providerConfigRef:provider
    } and
    $old[0].spec=={
      managementPolicies:managed,
      forProvider:{
        name:"Require workflow - Monorepo CI aggregate contract",target:"branch",enforcement:"active",
        conditions:[{refName:[{include:["~DEFAULT_BRANCH"],exclude:[]}],repositoryId:[786274843]}],
        rules:[{requiredWorkflows:[{requiredWorkflow:[{
          repositoryId:786274843,path:".github/workflows/ci-aggregate-contract.yaml",ref:"refs/heads/main"
        }]}]}]
      },
      providerConfigRef:provider
    } and all(($org+$repo+$old)[]; .metadata.namespace==null and
      .metadata.annotations["crossplane.io/external-name"]==null)
  ' "$1" >/dev/null
}
check_ci() {
  yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1" |
    jq -e '[.[] | select(.run=="bash tests/repository-admission-ruleset.sh")] |
      length==1 and (.[0] | .if==null and .["continue-on-error"]==null)' >/dev/null
}
kubectl kustomize "$root/deploy" > "$work/render.yaml"
yq -o=json -I=0 "." "$work/render.yaml" | jq -s "." > "$work/render.json"
check_render "$work/render.json" || fail 'canary, producer binding or original trusted gate changed'
check_ci "$root/.github/workflows/ci.yaml" || fail 'required policy test is absent or skippable'
count=0
for name in require-repository-pr-admission monorepo-require-reviewed-admission require-monorepo-ci-aggregate-contract; do
  for mutation in \
    '.spec.managementPolicies += ["Delete"]' \
    '.spec.managementPolicies = ["Observe"]' \
    '.spec.forProvider.enforcement="disabled"' \
    '.spec.forProvider.target="tag"' \
    '.spec.forProvider.bypassActors=[{"actorType":"OrganizationAdmin","bypassMode":"always"}]' \
    '.spec.forProvider.conditions[0].refName[0].include=["~ALL"]' \
    '.metadata.namespace="elsewhere"' \
    '.metadata.annotations["crossplane.io/external-name"]="123"'; do
    jq --arg name "$name" "map(if .metadata.name==\$name then ($mutation) else . end)" "$work/render.json" > "$work/broken.json"
    if check_render "$work/broken.json"; then fail "accepted $mutation on $name"; fi
    count=$((count+1))
  done
  jq --arg name "$name" '. + [.[] | select(.metadata.name==$name)]' "$work/render.json" > "$work/broken.json"
  if check_render "$work/broken.json"; then fail "accepted duplicate $name"; fi
  count=$((count+1))
done
for mutation in \
  '.spec.forProvider.conditions[0].repositoryId += [933213756]' \
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].repositoryId=786274843' \
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].ref="refs/heads/feature"' \
  '.spec.forProvider.rules[0].requiredWorkflows[0].requiredWorkflow[0].path=".github/workflows/ci.yaml"'; do
  jq "map(if .metadata.name==\"require-repository-pr-admission\" then ($mutation) else . end)" "$work/render.json" > "$work/broken.json"
  if check_render "$work/broken.json"; then fail 'accepted widened canary or substituted source'; fi
  count=$((count+1))
done
for mutation in \
  '.spec.forProvider.repository=".github"' \
  '.spec.forProvider.rules[0].requiredStatusChecks[0].requiredCheck[0].context="Admission not selected"' \
  '.spec.forProvider.rules[0].requiredStatusChecks[0].requiredCheck[0].integrationId=123'; do
  jq "map(if .metadata.name==\"monorepo-require-reviewed-admission\" then ($mutation) else . end)" "$work/render.json" > "$work/broken.json"
  if check_render "$work/broken.json"; then fail 'accepted a skipped result, another producer or another product'; fi
  count=$((count+1))
done
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/repository-admission-ruleset.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/repository-admission-ruleset.sh")).if="false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run=="bash tests/repository-admission-ruleset.sh"))["continue-on-error"]=true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" > "$work/ci.yaml"
  if check_ci "$work/ci.yaml"; then fail 'accepted skipped or missing required CI invocation'; fi
  count=$((count+1))
done
printf 'repository admission policy: additive monorepo canary and %s refusal controls passed\n' "$count"
