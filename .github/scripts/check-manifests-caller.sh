#!/usr/bin/env bash
# Keep the configuration release tag-only and uncallable.
# The platform trusts exactly this repository's cd.yaml on a release tag as the github-config
# signer. A caller of a reusable workflow signs with that workflow's identity, so making this
# workflow callable would let another workflow obtain its identity: admit only the release-tag path.
set -euo pipefail
fail() {
  echo "FAIL: configuration caller: $*" >&2
  exit 1
}
[[ "$#" == 1 ]] || fail 'expected one caller workflow'
caller="$1"
documents="$(yq -o=json -I=0 '.' "$caller")" || fail 'cannot read caller workflow'
jq -e -s '
  length == 1 and
  (.[0] |
    ((keys - ["name", "on", "permissions", "jobs"]) | length == 0) and
    .on == {"push":{"tags":["v*"]}} and
    .permissions == {} and
    (.jobs | keys) == ["publish-manifests"] and
    (.jobs["publish-manifests"] |
      ((keys - ["name", "runs-on", "timeout-minutes", "concurrency", "permissions", "steps"]) | length == 0) and
      .["runs-on"] == "ubuntu-latest" and .["timeout-minutes"] == 60 and
      .concurrency == {"group":"publish-verified-devantler-tech/github-config","queue":"max","cancel-in-progress":false} and
      .permissions == {"contents":"read","packages":"write","id-token":"write"} and
      (.steps | length == 3) and
      all(.steps[]; ((keys - ["name", "uses", "with"]) | length == 0)) and
      (.steps[0].uses | test("^step-security/harden-runner@[0-9a-f]{40}$")) and
      .steps[0].with == {"egress-policy":"audit"} and
      (.steps[1].uses | test("^actions/checkout@[0-9a-f]{40}$")) and
      .steps[1].with == {"fetch-depth":0,"persist-credentials":false} and
      .steps[2].uses == "$/actions/publish-app" and
      .steps[2].with == {"mode":"manifests","oci-name":"devantler-tech/github-config"}
    )
  )
' <<<"$documents" >/dev/null || fail 'expected the tag-only own-release signing contract'
echo 'ok configuration caller signs its own non-callable release tags with verified publication'
