#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() {
  echo "prebuilt-webapp: $*" >&2
  exit 1
}
workflow="$root/.github/workflows/publish-app.yaml"
yq -o=json '.' "$workflow" | jq -e '
  .on.workflow_call.inputs["enable-prebuilt-webapp"].default == false
' > /dev/null || fail 'missing default-off prebuilt WebApp capability'
yq -o=json '.' "$workflow" | jq -e '
  .jobs.publish as $job | $job.steps as $steps |
  .permissions == {} and
  $job.permissions == {contents:"read",packages:"write","id-token":"write"} and
  $job.concurrency["cancel-in-progress"] == false and
  ([.on.workflow_call.inputs | to_entries[] |
    select(.key | startswith("prebuilt-")) |
    .value | .type == "string" and .default == "" and .required == false] | length == 4 and all(.[]; .)) and
  ($steps | map(select(.id == "prebuilt")) | length) == 1 and
  ($steps | map(select(.id == "prebuilt"))[0] |
    .if == "${{ inputs.enable-prebuilt-webapp }}" and
    .run == "bash \"$RUNNER_TEMP/prepare-prebuilt-webapp.sh\"" and
    .env == {
      REPOSITORY:"${{ github.repository }}",SOURCE_SHA:"${{ github.sha }}",
      APP_NAME:"${{ inputs.app-name }}",DEPLOY_PATH:"${{ inputs.deploy-path }}",
      PREBUILT_IMAGE_DIGEST:"${{ inputs.prebuilt-image-digest }}",
      PREBUILT_PUBLIC_DIGEST:"${{ inputs.prebuilt-public-digest }}",
      PREBUILT_CI_RUN_ID:"${{ inputs.prebuilt-ci-run-id }}",
      PREBUILT_CI_RUN_ATTEMPT:"${{ inputs.prebuilt-ci-run-attempt }}"} and
    (has("continue-on-error") | not)) and
  ($steps | map(select(.id == "build"))[0].if ==
    "${{ !inputs.enable-signed-recovery && !inputs.enable-prebuilt-webapp }}") and
  ($steps | to_entries | map(select(.value.id == "prebuilt"))[0].key) <
    ($steps | to_entries | map(select(.value.id == "build"))[0].key) and
  ([ $steps[] | select(.run? | strings | contains("prepare-prebuilt-webapp.sh")) ] | length) == 2
' > /dev/null || fail 'prebuilt mode authority, input forwarding or verification order changed'

mkdir -p "$work/bin" "$work/deploy"
image_digest="sha256:$(printf 'a%.0s' {1..64})"
public_digest="$(printf 'b%.0s' {1..64})"
source_sha="$(printf 'c%.0s' {1..40})"
identity=https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main
jq -n --arg sha "$source_sha" '{
  id:123,run_attempt:2,status:"completed",conclusion:"success",event:"push",
  head_sha:$sha,head_branch:"main",path:".github/workflows/ci.yaml",
  repository:{full_name:"devantler-tech/app"},head_repository:{full_name:"devantler-tech/app"}
}' > "$work/run.json"
jq -n --arg digest "$image_digest" --arg sha "$source_sha" --arg public "$public_digest" '[{
  critical:{identity:{"docker-reference":("ghcr.io/devantler-tech/app@"+$digest)},image:{"docker-manifest-digest":$digest}},
  optional:{"devantler.repository":"devantler-tech/app","devantler.source-sha":$sha,
    "devantler.public-digest":$public,"devantler.public-profile":"production-template",
    "devantler.ci-run-id":"123","devantler.ci-run-attempt":"2",
    "devantler.run-id":"123","devantler.run-attempt":"2","devantler.workflow-sha":$sha}
}]' > "$work/signature.json"
jq -n --arg sha "$source_sha" --arg digest "${image_digest#sha256:}" --arg public "$public_digest" --arg identity "$identity" '{
  predicateType:"https://slsa.dev/provenance/v0.2",
  subject:[{name:"ghcr.io/devantler-tech/app",digest:{sha256:$digest}}],
  predicate:{builder:{id:$identity},buildType:"https://devantler.tech/build-types/combined-runtime-container/v1",
    invocation:{configSource:{uri:"git+https://github.com/devantler-tech/app",digest:{sha1:$sha},entryPoint:".github/workflows/ci.yaml"},
      parameters:{ciRunId:"123",ciRunAttempt:"2",publicDigest:$public,publicProfile:"production-template"}},
    metadata:{buildInvocationId:"https://github.com/devantler-tech/app/actions/runs/123"},
    materials:[{uri:"git+https://github.com/devantler-tech/app",digest:{sha1:$sha}}]}
}' > "$work/statement.json"

cat > "$work/bin/curl" << 'CURL'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" != *Authorization* ]] || exit 81
case "${*: -1}" in
  https://api.github.com/repos/devantler-tech/app/actions/runs/123|https://api.github.com/repos/devantler-tech/app/actions/runs/123/attempts/2) ;;
  *) exit 82 ;;
esac
printf 'read\n' >> "$FIXTURE/reads"
cat "$FIXTURE/current-run.json"
if [[ "$FAULT" == attempt-changed && "$(grep -c '^read$' "$FIXTURE/reads")" == 3 ]]; then
  printf '{"run_attempt":3}\n'
fi
[[ "$FAULT" != partial-read ]] || exit 83
CURL
cat > "$work/bin/cosign" << 'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'--certificate-identity https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main'* ]] || exit 84
[[ "$*" == *'--certificate-oidc-issuer https://token.actions.githubusercontent.com'* ]] || exit 85
[[ "${*: -1}" == "$IMAGE_REF" ]] || exit 86
printf '%s\n' "$1" >> "$FIXTURE/reads"
case "$1" in
  verify)
    for pair in "repository=devantler-tech/app" "source-sha=$SOURCE_SHA" "public-digest=$PREBUILT_PUBLIC_DIGEST" "public-profile=production-template" "ci-run-id=123" "ci-run-attempt=2" "run-id=123" "run-attempt=2" "workflow-sha=$SOURCE_SHA"; do
      [[ "$*" == *"-a devantler.$pair"* ]] || exit 87
    done
    cat "$FIXTURE/current-signature.json"
    [[ "$FAULT" != partial-signature ]] || exit 88
    ;;
  verify-attestation)
    [[ "$*" == *'--type slsaprovenance'* ]] || exit 89
    jq -nc --arg payload "$(base64 < "$FIXTURE/current-statement.json" | tr -d '\n')" '{payload:$payload}'
    [[ "$FAULT" != partial-attestation ]] || exit 90
    ;;
  *) exit 91 ;;
esac
COSIGN
chmod +x "$work/bin/curl" "$work/bin/cosign"

reset_fixture() {
  cp "$work/run.json" "$work/current-run.json"
  cp "$work/signature.json" "$work/current-signature.json"
  cp "$work/statement.json" "$work/current-statement.json"
  printf '%s\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"unrelated"},"data":{"literal":"keep me"}}' \
    '---' '{"apiVersion":"kro.run/v1alpha1","kind":"WebApp","metadata":{"name":"app","namespace":"app"},"spec":{"name":"app","image":"ghcr.io/devantler-tech/app:old","host":"example.invalid"}}' > "$work/deploy/webapp.yaml"
  cp "$work/deploy/webapp.yaml" "$work/before.yaml"
  : > "$work/output"
  : > "$work/reads"
}
invoke() {
  local fault="$1"
  shift
  (cd "$work" && env PATH="$work/bin:$PATH" FIXTURE="$work" FAULT="$fault" \
    REPOSITORY=devantler-tech/app SOURCE_SHA="$source_sha" APP_NAME=app DEPLOY_PATH=./deploy \
    PREBUILT_IMAGE_DIGEST="$image_digest" PREBUILT_PUBLIC_DIGEST="$public_digest" \
    PREBUILT_CI_RUN_ID=123 PREBUILT_CI_RUN_ATTEMPT=2 IMAGE_REF="ghcr.io/devantler-tech/app@$image_digest" \
    GITHUB_OUTPUT="$work/output" "$@" bash "$root/.github/scripts/prepare-prebuilt-webapp.sh")
}
reset_fixture
invoke none > "$work/log" 2>&1 || fail "healthy source-bound WebApp refused: $(cat "$work/log")"
yq -o=json -I=0 '.' "$work/deploy/webapp.yaml" | jq -s -e --arg image "ghcr.io/devantler-tech/app@$image_digest" '
  . == [
    {apiVersion:"v1",kind:"ConfigMap",metadata:{name:"unrelated"},data:{literal:"keep me"}},
    {apiVersion:"kro.run/v1alpha1",kind:"WebApp",metadata:{name:"app",namespace:"app"},
      spec:{name:"app",image:$image,host:"example.invalid"}}
  ]' > /dev/null || fail 'did not pin only the selected image and preserve other documents'
grep -qx "digest=$image_digest" "$work/output" || fail 'missing verified image output'
grep -qx "public-digest=$public_digest" "$work/output" || fail 'missing verified public digest output'

for fault in partial-read partial-signature partial-attestation attempt-changed; do
  reset_fixture
  if invoke "$fault" > "$work/log" 2>&1; then fail "accepted $fault"; fi
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail "$fault changed manifests"
  [[ ! -s "$work/output" ]] || fail "$fault exposed successful outputs"
done
for expression in 'null' '[]' '{}' '., .'; do
  reset_fixture
  jq "$expression" "$work/run.json" > "$work/current-run.json"
  if invoke none > "$work/log" 2>&1; then fail "accepted malformed or repeated CI evidence: $expression"; fi
  [[ ! -s "$work/output" ]] || fail 'malformed evidence produced outputs'
done
for expression in 'null' '[]' '{}' '., .' '.[0].critical.identity["docker-reference"]="other"' '.[0].critical.image["docker-manifest-digest"]="wrong"'; do
  reset_fixture
  jq "$expression" "$work/signature.json" > "$work/current-signature.json"
  if invoke none > "$work/log" 2>&1; then fail "accepted incomplete or conflicting signature evidence: $expression"; fi
  [[ ! -s "$work/output" ]] || fail 'invalid signature produced outputs'
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail 'invalid signature changed manifests'
done
for setting in 'REPOSITORY=../app' 'SOURCE_SHA=main' 'APP_NAME=../app' 'DEPLOY_PATH=../deploy' 'DEPLOY_PATH=/deploy' 'DEPLOY_PATH=./deploy/../deploy' 'PREBUILT_IMAGE_DIGEST=latest' 'PREBUILT_PUBLIC_DIGEST=wrong' 'PREBUILT_CI_RUN_ID=0' 'PREBUILT_CI_RUN_ID=99999999999999999' 'PREBUILT_CI_RUN_ATTEMPT=0'; do
  reset_fixture
  if invoke none "$setting" > "$work/log" 2>&1; then fail "accepted unsafe input: $setting"; fi
  [[ ! -s "$work/output" && ! -s "$work/reads" ]] || fail 'invalid input reached an external observation'
done
for expression in '.head_sha="wrong"' '.run_attempt=1' '.conclusion="failure"' '.status="in_progress"' '.event="pull_request"' '.head_branch="feature"' '.path=".github/workflows/other.yaml"' '.head_repository.full_name="other/app"' '.repository.full_name="other/app"' '.id=124'; do
  reset_fixture
  jq "$expression" "$work/run.json" > "$work/current-run.json"
  if invoke none > "$work/log" 2>&1; then fail "accepted conflicting CI evidence: $expression"; fi
  [[ ! -s "$work/output" ]] || fail 'conflicting CI evidence produced outputs'
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail 'conflicting CI evidence changed manifests'
done
for expression in '.subject[0].digest.sha256="wrong"' '.subject[0].name="other/app"' '.predicate.builder.id="other"' '.predicateType="other"' '.predicate.buildType="other"' '.predicate.invocation.configSource.digest.sha1="wrong"' '.predicate.invocation.configSource.uri="other"' '.predicate.invocation.configSource.entryPoint="other"' '.predicate.invocation.parameters.ciRunAttempt="1"' '.predicate.invocation.parameters.ciRunId="124"' '.predicate.invocation.parameters.publicDigest="wrong"' '.predicate.invocation.parameters.publicProfile="default"' '.predicate.materials[0].digest.sha1="wrong"' '.predicate.metadata.buildInvocationId="other"'; do
  reset_fixture
  jq "$expression" "$work/statement.json" > "$work/current-statement.json"
  if invoke none > "$work/log" 2>&1; then fail "accepted conflicting signed provenance: $expression"; fi
  [[ ! -s "$work/output" ]] || fail 'conflicting provenance produced outputs'
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail 'conflicting provenance changed manifests'
done
for expression in '.[1].metadata.namespace="other"' '.[1].spec.name="other"' '.[1].kind="Deployment"' '. += [.[1]]'; do
  reset_fixture
  yq -o=json -I=0 '.' "$work/deploy/webapp.yaml" | jq -s "$expression" | yq -p=json '.[] | split_doc' > "$work/deploy/changed.yaml"
  mv "$work/deploy/changed.yaml" "$work/deploy/webapp.yaml"
  cp "$work/deploy/webapp.yaml" "$work/before.yaml"
  if invoke none > "$work/log" 2>&1; then fail "accepted ambiguous or different WebApp: $expression"; fi
  [[ ! -s "$work/output" ]] || fail 'invalid WebApp produced outputs'
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail 'invalid WebApp was changed'
done
reset_fixture
mv "$work/deploy/webapp.yaml" "$work/original.yaml"
ln -s "$work/original.yaml" "$work/deploy/webapp.yaml"
if invoke none > "$work/log" 2>&1; then fail 'accepted symlinked manifest'; fi
[[ ! -s "$work/output" ]] || fail 'linked manifest produced outputs'
rm "$work/deploy/webapp.yaml"
reset_fixture
ln -s "$work/run.json" "$work/deploy/unrelated.yaml"
if invoke none > "$work/log" 2>&1; then fail 'accepted a linked file in the packaged deployment directory'; fi
[[ ! -s "$work/output" && ! -s "$work/reads" ]] || fail 'linked deployment file reached verification'
echo 'prebuilt-webapp: real YAML pinning and source/CI/provenance/partial-observation refusals pass'
