#!/usr/bin/env bash
# A failed or ambiguous read must never authorize publication.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${1:-$root/.github/scripts/require-unpublished-version.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TRACE"
output=''
url=''
for arg in "$@"; do
  if [[ "${previous:-}" == --output ]]; then output="$arg"; fi
  case "$arg" in https://*) url="$arg" ;; esac
  previous="$arg"
done
[[ -n "$output" && "$*" != *' --location '* ]] || exit 99
[[ "$*" == *'--proto =https'* && "$*" == *'--max-time 30'* ]] || exit 98
case "$url" in
  https://ghcr.io/token)
    [[ "$*" == *'--user fixture:synthetic-token'* && "$*" == *'scope=repository:devantler-tech/app'* ]] || exit 97
    case "$SCENARIO" in
      token-transport) exit 7 ;;
      token-forbidden) printf '{}' >"$output"; printf 403 ;;
      token-malformed) printf '{' >"$output"; printf 200 ;;
      token-empty) printf '{"token":""}' >"$output"; printf 200 ;;
      token-injection) printf '{"token":"bad\\nheader"}' >"$output"; printf 200 ;;
      token-padded) printf '{"token":"synthetic+bearer/=="}' >"$output"; printf 200 ;;
      token-multiple) printf '{"token":"synthetic-bearer"}\n{"token":"synthetic-bearer"}' >"$output"; printf 200 ;;
      token-conflict) printf '{"token":"synthetic-bearer","access_token":"different"}' >"$output"; printf 200 ;;
      *) printf '{"token":"synthetic-bearer"}' >"$output"; printf 200 ;;
    esac
    ;;
  https://ghcr.io/v2/devantler-tech/app/manifests/1.2.3|https://ghcr.io/v2/devantler-tech/app/manifests/manifests/1.2.3)
    if [[ "$SCENARIO" == token-padded ]]; then
      [[ "$*" == *'Authorization: Bearer synthetic+bearer/=='* ]] || exit 96
    else
      [[ "$*" == *'Authorization: Bearer synthetic-bearer'* ]] || exit 96
    fi
    [[ "$*" == *'application/vnd.oci.image.index.v1+json'* && "$*" == *'application/vnd.docker.distribution.manifest.list.v2+json'* ]] || exit 95
    case "$SCENARIO" in
      transport) exit 7 ;;
      forbidden) printf '{"errors":[{"code":"DENIED"}]}' >"$output"; printf 403 ;;
      throttled) printf '{}' >"$output"; printf 429 ;;
      server) printf '{}' >"$output"; printf 503 ;;
      redirect) printf '{}' >"$output"; printf 302 ;;
      malformed) printf '{' >"$output"; printf 404 ;;
      empty) printf '{"errors":[]}' >"$output"; printf 404 ;;
      wrong-code) printf '{"errors":[{"code":"DENIED"}]}' >"$output"; printf 404 ;;
      mixed-errors) printf '{"errors":[{"code":"MANIFEST_UNKNOWN"},{"code":"DENIED"}]}' >"$output"; printf 404 ;;
      missing-code) printf '{"errors":[{}]}' >"$output"; printf 404 ;;
      multiple-documents) printf '{"errors":[{"code":"DENIED"}]}\n{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404 ;;
      exists) printf '{}' >"$output"; printf 200 ;;
      image-only)
        if [[ "$url" == */app/manifests/1.2.3 ]]; then printf '{}' >"$output"; printf 200;
        else printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404; fi ;;
      manifests-only)
        if [[ "$url" == */app/manifests/manifests/1.2.3 ]]; then printf '{}' >"$output"; printf 200;
        else printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404; fi ;;
      missing-repository) printf '{"errors":[{"code":"NAME_UNKNOWN"}]}' >"$output"; printf 404 ;;
      *) printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404 ;;
    esac
    ;;
  *) exit 94 ;;
esac
CURL
chmod +x "$work/bin/curl"
validate_binding() {
  yq -o=json '.' "$1" | jq -e '
    .jobs[] | .steps as $steps |
    [$steps | to_entries[] | select(.value.name == "🔒 Refuse an occupied release version")] as $guard |
    ($guard | length) == 1 and $guard[0].value.if == "${{ !inputs.enable-signed-recovery }}" and
    all($steps | to_entries[] | select(.value.id == "build" or .value.name == "📦 Push & sign manifests artifact");
      .key > $guard[0].key) and
    all($steps[] | select(.name == "🔒 Reserve publisher helper checkout" or
      .name == "📑 Checkout immutable publisher helpers" or .name == "🔒 Prepare immutable publication guard");
      has("if") | not)' >/dev/null
}
if [[ "$#" == 0 ]]; then
  for workflow in publish-app publish-manifests; do
    yq -o=json '.' "$root/.github/workflows/$workflow.yaml" | jq -e '
      .on.workflow_call.inputs["enable-signed-promotion"].default == false and
      ([.jobs[].steps[] | select(.name == "📑 Checkout immutable publisher helpers") |
        .with.repository == "${{ job.workflow_repository }}" and
        .with.ref == "${{ job.workflow_sha }}" and
        .with.path == ".devantler-tech-publisher" and
        .with["persist-credentials"] == false] == [true])' >/dev/null || {
      echo 'FAIL: publication guard is not bound to the immutable workflow source'; exit 1;
    }
    production="$root/.github/workflows/$workflow.yaml"
    yq -r '.jobs[].steps[] | select(.name == "🔒 Refuse an occupied release version") | .run' \
      "$production" >"$work/admission.sh"
    [[ -s "$work/admission.sh" ]] || { echo "FAIL: $workflow has no default version admission"; exit 1; }
    cp "$script" "$work/require-unpublished-version.sh"
    for scenario in absent exists token-transport forbidden malformed redirect; do
      : >"$work/trace"
      status=0
      env -i PATH="$work/bin:$PATH" TRACE="$work/trace" SCENARIO="$scenario" REGISTRY=ghcr.io \
        IMAGE_NAME=devantler-tech/app OCI_NAME=devantler-tech/app REPOSITORY=devantler-tech/app \
        VERSION=1.2.3 ACTOR=fixture GH_TOKEN=synthetic-token RUNNER_TEMP="$work" \
        bash "$work/admission.sh" >"$work/log" 2>&1 || status=$?
      if [[ "$scenario" == absent ]]; then
        [[ "$status" == 0 ]] || { cat "$work/log"; exit 1; }
        expected_reads=2
        [[ "$workflow" != publish-app ]] || expected_reads=4
        [[ "$(wc -l <"$work/trace" | tr -d ' ')" == "$expected_reads" ]] || {
          echo "FAIL: default $workflow omitted a publication target"; exit 1;
        }
      else
        [[ "$status" != 0 ]] || { echo "FAIL: default $workflow $scenario authorized publication"; exit 1; }
      fi
    done
    validate_binding "$production" || {
      echo "FAIL: $workflow default version refusal is not before every registry write"; exit 1;
    }
    for mutation in deleted gated late helper-gated; do
      # shellcheck disable=SC2016 # Workflow expressions in negative controls.
      case "$mutation" in
        deleted) expression='.jobs[].steps |= map(select(.name != "🔒 Refuse an occupied release version"))' ;;
        gated) expression='(.jobs[].steps[] | select(.name == "🔒 Refuse an occupied release version")).if = "${{ inputs.enable-signed-promotion }}"' ;;
        late) expression='.jobs[].steps |= (map(select(.name != "🔒 Refuse an occupied release version")) + map(select(.name == "🔒 Refuse an occupied release version")))' ;;
        helper-gated) expression='(.jobs[].steps[] | select(.name == "📑 Checkout immutable publisher helpers")).if = "${{ inputs.enable-signed-promotion }}"' ;;
      esac
      yq "$expression" "$production" >"$work/mutated.yaml"
      if validate_binding "$work/mutated.yaml"; then echo "FAIL: $workflow accepted $mutation version admission"; exit 1; fi
    done
  done
fi
for scenario in absent missing-repository token-padded exists image-only manifests-only token-transport token-forbidden token-malformed token-empty token-injection token-multiple token-conflict transport forbidden throttled server redirect malformed empty wrong-code mixed-errors missing-code multiple-documents; do
  : >"$work/trace"
  status=0
  env -i PATH="$work/bin:$PATH" TRACE="$work/trace" SCENARIO="$scenario" REGISTRY=ghcr.io \
    OCI_REPOSITORIES=$'devantler-tech/app\ndevantler-tech/app/manifests' VERSION=1.2.3 \
    ACTOR=fixture GH_TOKEN=synthetic-token bash "$script" >"$work/log" 2>&1 || status=$?
  case "$scenario" in
    absent|missing-repository|token-padded)
      [[ "$status" == 0 ]] || { cat "$work/log"; exit 1; }
      [[ "$(wc -l <"$work/trace" | tr -d ' ')" == 4 ]] || { echo 'FAIL: did not inspect both targets'; exit 1; }
      ;;
    *) [[ "$status" != 0 ]] || { echo "FAIL: $scenario authorized publication"; exit 1; } ;;
  esac
  if grep -Eq 'synthetic-token|synthetic-bearer' "$work/log"; then echo 'FAIL: credential printed'; exit 1; fi
done
for version in '' '1.2.3+build' '../other' $'1.2.3\nheader'; do
  : >"$work/trace"
  if env -i PATH="$work/bin:$PATH" TRACE="$work/trace" SCENARIO=absent REGISTRY=ghcr.io \
    OCI_REPOSITORIES=devantler-tech/app VERSION="$version" ACTOR=fixture GH_TOKEN=synthetic-token \
    bash "$script" >"$work/log" 2>&1; then echo 'FAIL: invalid version accepted'; exit 1; fi
  [[ ! -s "$work/trace" ]] || { echo 'FAIL: invalid version reached registry'; exit 1; }
done
echo 'PASS: authenticated absence, both partial versions, read failures, malformed evidence and credential silence'
if [[ "$#" == 0 ]]; then
  printf '#!/usr/bin/env bash\nexit 0\n' >"$work/always-pass.sh"
  if bash "$0" "$work/always-pass.sh" >"$work/ablation.log" 2>&1; then
    echo 'FAIL: removed version refusal was not detected'; exit 1
  fi
  grep -q 'did not inspect both targets' "$work/ablation.log"
  echo 'PASS: removing the actual guard is rejected'
fi
