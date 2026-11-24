#!/usr/bin/env bash
# Pins who may create a release tag (#924): the one creation ruleset covers every repository
# and carries exactly the release identities from the census, and "Protect release tags" keeps
# no bypass actor, because a bypass there would also bypass its delete and force-move rules.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'release-tag-creation-ruleset: %s\n' "$*" >&2; return 1; }
lifecycle='["Observe","Create","Update","LateInitialize"]'
refs='[{"include":["refs/tags/v*","refs/tags/v*/**/*"],"exclude":[]}]'
provider='{"kind":"ProviderConfig","name":"default"}'
organization="$(jq -cn --argjson lifecycle "$lifecycle" --argjson refs "$refs" --argjson provider "$provider" '{
  managementPolicies: $lifecycle,
  forProvider: {
    name: "Restrict release tag creation", target: "tag", enforcement: "active",
    bypassActors: [
      {actorType: "Integration", actorId: 1025824, bypassMode: "always"},
      {actorType: "OrganizationAdmin", bypassMode: "always"}
    ],
    conditions: [{refName: $refs, repositoryName: [{include: ["~ALL"], exclude: []}]}],
    rules: [{creation: true}]
  },
  providerConfigRef: $provider
}')"
check_rules() {
  local observed
  observed="$(yq -o=json -I=0 '.' "$1" | jq -s '[.[] | select(.kind == "OrganizationRuleset")]')" || { fail 'unreadable render'; return 1; }
  jq -e --argjson organization "$organization" '
    def one($name): [.[] | select(.metadata.name == $name)];
    def created($name; $spec):
      one($name) | length == 1
        and .[0].apiVersion == "enterprise.github.m.upbound.io/v1alpha1"
        and .[0].spec == $spec
        and ((.[0].metadata.annotations // {}) | has("crossplane.io/external-name") | not);
    created("restrict-release-tag-creation"; $organization)
    # Only this ruleset may restrict tag creation, so no other bypass list applies to it.
    and ([.[] | select(.spec.forProvider.target == "tag" and any(.spec.forProvider.rules[]?; .creation == true))
          | .metadata.name] == ["restrict-release-tag-creation"])
    and (one("protect-release-tags") | length == 1
      and (.[0].spec.forProvider | (.bypassActors // []) == [] and .target == "tag"
        and (.rules | length == 1 and (.[0] | .deletion == true and .nonFastForward == true and (has("creation") | not)))))
  ' <<< "$observed" >/dev/null || { fail 'unexpected release tag policy'; return 1; }
}
check_ci() {
  local steps
  steps="$(yq -o=json -I=0 '.jobs["validate-manifests"].steps' "$1")" || { fail 'unreadable CI'; return 1; }
  jq -e '[.[] | select(.run == "bash tests/release-tag-creation-ruleset.sh")]
    | length == 1 and (.[0] | has("if") | not)
      and (.[0] | has("continue-on-error") | not)' <<< "$steps" >/dev/null || { fail 'missing unconditional CI guard'; return 1; }
}
kubectl kustomize "$root/deploy" > "$work/render.yaml" || { fail 'render failed'; exit 1; }
check_rules "$work/render.yaml"
check_ci "$root/.github/workflows/ci.yaml"
# Exercise the rendered policies, not second synthetic resources.
organization_selector='select(.kind == "OrganizationRuleset" and .metadata.name == "restrict-release-tag-creation")'
protect_selector='select(.kind == "OrganizationRuleset" and .metadata.name == "protect-release-tags")'
mutations=(
  "${organization_selector}|del(.spec.managementPolicies)"
  "${organization_selector}|.spec.managementPolicies += [\"Delete\"]"
  "${organization_selector}|.spec.managementPolicies = [\"Observe\"]"
  "${organization_selector}|.spec.managementPolicies = [\"Observe\",\"Create\",\"Update\"]"
  "${organization_selector}|.spec.forProvider.enforcement = \"disabled\""
  "${organization_selector}|.spec.forProvider.enforcement = \"evaluate\""
  "${organization_selector}|.spec.forProvider.target = \"branch\""
  "${organization_selector}|.spec.forProvider.rules = []"
  "${organization_selector}|.spec.forProvider.rules[0].creation = false"
  "${organization_selector}|.spec.forProvider.bypassActors += [{\"actorType\":\"Integration\",\"actorId\":15368,\"bypassMode\":\"always\"}]"
  "${organization_selector}|.spec.forProvider.bypassActors += [{\"actorType\":\"RepositoryRole\",\"actorId\":5,\"bypassMode\":\"always\"}]"
  "${organization_selector}|.spec.forProvider.bypassActors += [{\"actorType\":\"DeployKey\",\"bypassMode\":\"always\"}]"
  "${organization_selector}|.spec.forProvider.bypassActors[0].actorId = 4126012"
  "${organization_selector}|.spec.forProvider.bypassActors[1].actorType = \"RepositoryRole\""
  "${organization_selector}|del(.spec.forProvider.bypassActors[1])"
  "${organization_selector}|.spec.forProvider.bypassActors[0].bypassMode = \"exempt\""
  "${organization_selector}|.spec.forProvider.bypassActors += [{\"actorType\":\"Integration\",\"actorId\":2880167,\"bypassMode\":\"always\"}]"
  "${organization_selector}|.spec.forProvider.bypassActors += [{\"actorType\":\"Integration\",\"actorId\":5498800,\"bypassMode\":\"always\"}]"
  "${organization_selector}|.spec.forProvider.conditions[0].refName[0].include = [\"refs/tags/v*\"]"
  "${organization_selector}|.spec.forProvider.conditions[0].refName[0].include = [\"refs/tags/v1*\",\"refs/tags/v*/**/*\"]"
  "${organization_selector}|.spec.forProvider.conditions[0].refName[0].exclude = [\"refs/tags/v0*\"]"
  "${organization_selector}|.spec.forProvider.conditions[0].repositoryName[0].exclude += [\"platform\"]"
  "${organization_selector}|.spec.forProvider.conditions[0].repositoryName[0].exclude = [\"agent-plugins\"]"
  "${organization_selector}|.spec.forProvider.conditions[0].repositoryName[0].include = [\"ksail\"]"
  "${organization_selector}|.metadata.annotations.\"crossplane.io/external-name\" = \"18136026\""
  "${organization_selector}|.apiVersion = \"repo.github.m.upbound.io/v1alpha1\""
  "${organization_selector}|.spec.providerConfigRef.name = \"another-provider\""
  "${protect_selector}|.spec.forProvider.bypassActors = [{\"actorType\":\"Integration\",\"actorId\":1025824,\"bypassMode\":\"always\"}]"
  "${protect_selector}|.spec.forProvider.bypassActors = [{\"actorType\":\"OrganizationAdmin\",\"bypassMode\":\"always\"}]"
  "${protect_selector}|.spec.forProvider.rules[0].creation = true"
  "${protect_selector}|.spec.forProvider.rules[0].deletion = false"
  "${protect_selector}|del(.spec.forProvider.rules[0].nonFastForward)"
)
for mutation in "${mutations[@]}"; do
  selector="${mutation%%|*}"
  change="${mutation#*|}"
  yq "(${selector}) |= (${change})" "$work/render.yaml" > "$work/bad.yaml"
  if check_rules "$work/bad.yaml" > "$work/diagnostic" 2>&1; then fail "accepted mutation ${change} on ${selector}"; exit 1; fi
  grep -qF 'unexpected release tag policy' "$work/diagnostic"
done
# A duplicate or a third ruleset restricting tag creation would add another bypass list.
for control in duplicate extra-creation; do
  case "$control" in
  duplicate)
    { cat "$work/render.yaml"; printf -- '---\n'; yq "${organization_selector}" "$work/render.yaml"; } > "$work/bad.yaml"
    ;;
  extra-creation)
    { cat "$work/render.yaml"; printf -- '---\n'; yq "${organization_selector} | .metadata.name = \"another-creation-rule\" | .spec.forProvider.bypassActors = [{\"actorType\":\"Integration\",\"actorId\":15368,\"bypassMode\":\"always\"}] | .spec.forProvider.conditions[0].repositoryName[0] = {\"include\":[\"ksail\"],\"exclude\":[]}" "$work/render.yaml"; } > "$work/bad.yaml"
    ;;
  esac
  if check_rules "$work/bad.yaml" > "$work/diagnostic" 2>&1; then fail "accepted $control ruleset"; exit 1; fi
  grep -qF 'unexpected release tag policy' "$work/diagnostic"
done
# Plausible output followed by reader failure must not satisfy a conditional call.
mkdir "$work/bin"
real_yq="$(command -v yq)"
cat > "$work/bin/yq" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_YQ" "$@"
exit 42
WRAPPER
chmod +x "$work/bin/yq"
if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" check_rules "$work/render.yaml" > "$work/diagnostic" 2>&1; then fail 'accepted failed reader'; exit 1; fi
grep -qF 'unreadable render' "$work/diagnostic"
for mutation in \
  'del(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/release-tag-creation-ruleset.sh"))' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/release-tag-creation-ruleset.sh")).if = "false"' \
  '(.jobs["validate-manifests"].steps[] | select(.run == "bash tests/release-tag-creation-ruleset.sh")).continue-on-error = true'; do
  yq "$mutation" "$root/.github/workflows/ci.yaml" > "$work/ci.yaml"
  if check_ci "$work/ci.yaml" > "$work/diagnostic" 2>&1; then fail 'accepted weakened CI guard'; exit 1; fi
  grep -qF 'missing unconditional CI guard' "$work/diagnostic"
done
printf 'release-tag-creation-ruleset: PASS; exact release-identity bypass lists, bypass-free tag immutability and %d rejection controls\n' "$(( ${#mutations[@]} + 2 + 1 + 3 ))"
