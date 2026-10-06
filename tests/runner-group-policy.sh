#!/usr/bin/env bash
# Check the rendered group boundary; this does not establish live provider readiness.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

unknown() { echo "runner-group-policy: UNKNOWN — $*" >&2; exit 2; }
fail() { echo "runner-group-policy: $*" >&2; exit 1; }

case "$#" in
  0)
    kubectl kustomize "$repo_root/deploy" >"$scratch/render.yaml" ||
      unknown 'deploy/ did not render'
    render="$scratch/render.yaml"
    ;;
  2)
    [[ "$1" == --rendered ]] || unknown 'expected --rendered <file>'
    render="$2"
    [[ -f "$render" && -r "$render" ]] || unknown 'rendered input is unreadable'
    ;;
  *) unknown 'expected no arguments or --rendered <file>' ;;
esac

yq -o=json '.' "$render" >"$scratch/documents.json" ||
  unknown 'rendered YAML did not parse'
jq -s 'map(select(type == "object" and .kind == "RunnerGroup"))' \
  "$scratch/documents.json" >"$scratch/groups.json" ||
  unknown 'rendered documents could not be classified'

jq -e 'length == 1' "$scratch/groups.json" >/dev/null ||
  fail 'expected exactly one RunnerGroup'

jq -e '.[0] |
  .apiVersion == "actions.github.m.upbound.io/v1alpha1" and
  .metadata.name == "ksail-code-quality" and
  ((.metadata.namespace // "github-config") == "github-config") and
  ((.metadata.annotations // {}) | has("crossplane.io/external-name") | not)
' "$scratch/groups.json" >/dev/null ||
  fail 'expected the new namespaced KSail group, without an unverified external identity'

jq -e '.[0].spec |
  (keys | sort) == ["forProvider", "managementPolicies", "providerConfigRef"] and
  (.managementPolicies | sort) == ["Create", "Observe", "Update"] and
  .providerConfigRef == {"kind":"ProviderConfig", "name":"default"}
' "$scratch/groups.json" >/dev/null ||
  fail 'expected the existing provider and explicit management without deletion or late initialization'

jq -e '.[0].spec.forProvider |
  (keys | sort) == ["allowsPublicRepositories", "name", "restrictedToWorkflows", "selectedRepositoryIds", "selectedWorkflows", "visibility"] and
  .name == "ksail-code-quality" and
  .visibility == "selected" and
  .selectedRepositoryIds == [737584922] and
  .allowsPublicRepositories == true and
  .restrictedToWorkflows == false and
  .selectedWorkflows == []
' "$scratch/groups.json" >/dev/null ||
  fail 'expected an explicit public-capable group restricted to KSail alone'

echo 'runner-group-policy: KSail-only declaration is valid; live group readiness is not assessed'
