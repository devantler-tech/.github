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
  repository:{full_name:"devantler-tech/app",private:false},head_repository:{full_name:"devantler-tech/app",private:false}
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
[[ "${EXPECT_AUTH:-false}" != true || "$*" != *"$FIXTURE_TOKEN"* ]] || exit 100
case "${*: -1}" in
  https://api.github.com/repos/devantler-tech/app/actions/runs/123|https://api.github.com/repos/devantler-tech/app/actions/runs/123/attempts/2) ;;
  *) exit 82 ;;
esac
printf 'read\n' >> "$FIXTURE/reads"
output='' headers='' config='' write_status=false
[[ "$*" != *--location* && "$*" != *' -L '* && "$*" == *'--proto =https'* ]] || exit 95
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --write-out) [[ "$2" == '%{http_code}' ]] || exit 92; write_status=true; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${EXPECT_AUTH:-false}" == true ]]; then
  [[ -n "$config" && -z "${PREBUILT_CI_READ_TOKEN:-}" && -z "${ci_read_token:-}" ]] || exit 96
  [[ "$(ls -l "$config" | awk '{print substr($1,2,9)}')" == rw------- ]] || exit 97
  [[ "$(ls -ld "$(dirname "$config")" | awk '{print substr($1,2,9)}')" == rwx------ ]] || exit 101
  grep -Fxq "header = \"Authorization: Bearer $FIXTURE_TOKEN\"" "$config" || exit 98
  printf '%s\n' "$config" >> "$FIXTURE/auth-files"
else
  [[ -z "$config" ]] || exit 99
fi
status=200
response_headers='HTTP/2 200'
read_count="$(grep -c '^read$' "$FIXTURE/reads")"
case "$FAULT" in
  rate-transient)
    if [[ "$read_count" == 1 ]]; then status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 1'; fi ;;
  rate-attempt-read)
    if [[ "$read_count" == 2 ]]; then status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 1'; fi ;;
  rate-final-read)
    if [[ "$read_count" == 3 ]]; then status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 1'; fi ;;
  rate-primary)
    if [[ "$read_count" == 1 ]]; then status=403; response_headers=$'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nX-RateLimit-Reset: 1000000002'; fi ;;
  rate-both-delays)
    if [[ "$read_count" == 1 ]]; then status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 1\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1000000002'; fi ;;
  rate-secondary)
    if [[ "$read_count" == 1 ]]; then status=429; response_headers='HTTP/2 429'; fi ;;
  rate-secondary-persistent) status=429; response_headers='HTTP/2 429' ;;
  rate-budget)
    if [[ "$read_count" == 1 || "$read_count" == 3 || "$read_count" == 5 ]]; then
      status=429; response_headers=$'HTTP/2 429\r\nRetry-After: 60'
    fi ;;
  malformed-delay) status=403; response_headers=$'HTTP/2 403\r\nRetry-After: invalid' ;;
  duplicate-delay) status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 1\r\nretry-after: 1' ;;
  primary-long-reset) status=403; response_headers=$'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1000003600' ;;
  rate-persistent) status=429; response_headers=$'HTTP/2 429\r\nRetry-After: 1' ;;
  forbidden) status=403; response_headers=$'HTTP/2 403\r\nX-RateLimit-Remaining: 42' ;;
  redirect) status=302; response_headers='HTTP/2 302' ;;
  long-rate-limit) status=403; response_headers=$'HTTP/2 403\r\nRetry-After: 3600' ;;
esac
[[ -z "$headers" ]] || printf '%s\r\n\r\n' "$response_headers" > "$headers"
if [[ -n "$output" ]]; then
  cat "$FIXTURE/current-run.json" > "$output"
else
  cat "$FIXTURE/current-run.json"
fi
case "$FAULT:$read_count" in
  private-run:1) jq '.repository.private=true' "$output" > "$output.next"; mv "$output.next" "$output" ;;
  private-attempt:2) jq '.head_repository.private=true' "$output" > "$output.next"; mv "$output.next" "$output" ;;
  private-final:3) jq '.repository.private=true' "$output" > "$output.next"; mv "$output.next" "$output" ;;
esac
if [[ "$FAULT" == attempt-changed && "$(grep -c '^read$' "$FIXTURE/reads")" == 3 ]]; then
  if [[ -n "$output" ]]; then printf '{"run_attempt":3}\n' >> "$output"; else printf '{"run_attempt":3}\n'; fi
fi
if "$write_status"; then printf '%s' "$status"; fi
[[ "$status" == 200 ]] || exit 22
[[ "$FAULT" != partial-read ]] || exit 83
CURL
cat > "$work/bin/sleep" << 'SLEEP'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && "$1" =~ ^[0-9]+$ ]] || exit 93
printf '%s\n' "$1" >> "$FIXTURE/waits"
SLEEP
cat > "$work/bin/date" << 'DATE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '+%s' ]] || exit 94
printf '1000000000\n'
DATE
cat > "$work/bin/cosign" << 'COSIGN'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *'--certificate-identity https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main'* ]] || exit 84
[[ "$*" == *'--certificate-oidc-issuer https://token.actions.githubusercontent.com'* ]] || exit 85
[[ "${*: -1}" == "$IMAGE_REF" ]] || exit 86
[[ -z "${PREBUILT_CI_READ_TOKEN:-}" && -z "${ci_read_token:-}" ]] || exit 96
[[ -z "${FIXTURE_TOKEN:-}" || "$*" != *"$FIXTURE_TOKEN"* ]] || exit 100
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
chmod +x "$work/bin/curl" "$work/bin/cosign" "$work/bin/sleep" "$work/bin/date"

# Restore independent source, signature, provenance and output state for one case.
reset_fixture() {
  cp "$work/run.json" "$work/current-run.json"
  cp "$work/signature.json" "$work/current-signature.json"
  cp "$work/statement.json" "$work/current-statement.json"
  printf '%s\n' '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"unrelated"},"data":{"literal":"keep me"}}' \
    '---' '{"apiVersion":"kro.run/v1alpha1","kind":"WebApp","metadata":{"name":"app","namespace":"app"},"spec":{"name":"app","image":"ghcr.io/devantler-tech/app:old","host":"example.invalid"}}' > "$work/deploy/webapp.yaml"
  cp "$work/deploy/webapp.yaml" "$work/before.yaml"
  : > "$work/output"
  : > "$work/reads"
  : > "$work/waits"
  : > "$work/auth-files"
}
# Run the actual verifier with only its external observations replaced by fixtures.
invoke() {
  local fault="$1"
  shift
  (cd "$work" && env -u PREBUILT_CI_AUTH_MODE -u PREBUILT_CI_READ_TOKEN \
    PATH="$work/bin:$PATH" FIXTURE="$work" FAULT="$fault" \
    REPOSITORY=devantler-tech/app SOURCE_SHA="$source_sha" APP_NAME=app DEPLOY_PATH=./deploy \
    PREBUILT_IMAGE_DIGEST="$image_digest" PREBUILT_PUBLIC_DIGEST="$public_digest" \
    PREBUILT_CI_RUN_ID=123 PREBUILT_CI_RUN_ATTEMPT=2 IMAGE_REF="ghcr.io/devantler-tech/app@$image_digest" \
    EXPECT_AUTH=false \
    GITHUB_OUTPUT="$work/output" "$@" bash -x "$root/.github/scripts/prepare-prebuilt-webapp.sh")
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

# A real long stateless-shaped credential remains opaque and private throughout
# all three reads, bounded retries, signature checks and final failure cleanup.
fixture_token="ghs_123456_$(printf '%0600d' 0).opaque-fixture.signature-fixture"
for fault in none rate-transient rate-attempt-read rate-final-read forbidden redirect private-run private-attempt private-final attempt-changed partial-signature partial-attestation; do
  reset_fixture
  if invoke "$fault" PREBUILT_CI_AUTH_MODE=job-token PREBUILT_CI_READ_TOKEN="$fixture_token" \
    EXPECT_AUTH=true FIXTURE_TOKEN="$fixture_token" ci_read_token=ambient_export_attribute \
    GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
    > "$work/log" 2>&1; then verdict=accepted; else verdict=rejected; fi
  if grep -Fq "$fixture_token" "$work/log"; then fail 'credential reached traced output'; fi
  while IFS= read -r auth_file; do
    [[ ! -e "$auth_file" ]] || fail 'credential file survived verifier completion'
  done < "$work/auth-files"
  case "$fault" in
    none|rate-transient|rate-attempt-read|rate-final-read)
      [[ "$verdict" == accepted && -s "$work/output" ]] || fail "authenticated public verification refused $fault"
      [[ "$(wc -l < "$work/auth-files" | tr -d ' ')" == "$([[ "$fault" == none ]] && echo 3 || echo 4)" ]] || fail 'authenticated reads fell back or skipped a recheck' ;;
    *)
      [[ "$verdict" == rejected && ! -s "$work/output" ]] || fail "authenticated verifier accepted $fault"
      if [[ "$fault" == forbidden || "$fault" == redirect ]]; then
        [[ "$(wc -l < "$work/reads" | tr -d ' ')" == 1 ]] || fail 'authentication refusal fell back or retried'
      fi
      cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail "authenticated $fault changed manifests" ;;
  esac
done
reset_fixture
invoke none GH_TOKEN=ambient_fixture_must_not_be_used GITHUB_TOKEN=ambient_fixture_must_not_be_used \
  > "$work/log" 2>&1 || fail 'ambient credentials changed the anonymous default'
[[ ! -s "$work/auth-files" ]] || fail 'default mode used ambient authentication'
for setting in 'PREBUILT_CI_AUTH_MODE=unknown' 'PREBUILT_CI_AUTH_MODE=job-token' "PREBUILT_CI_READ_TOKEN=$fixture_token"; do
  reset_fixture
  if invoke none "$setting" > "$work/log" 2>&1; then fail 'accepted incomplete or unknown authentication opt-in'; fi
  [[ ! -s "$work/output" && ! -s "$work/reads" ]] || fail 'invalid authentication opt-in reached external verification'
done
for task_token in '' $'bad\r\nheader = injection' 'opaque"header' 'opaque\header'; do
  reset_fixture
  if invoke none PREBUILT_CI_AUTH_MODE=job-token PREBUILT_CI_READ_TOKEN="$task_token" \
    GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted > "$work/log" 2>&1; then fail 'accepted unsafe credential transport'; fi
  [[ ! -s "$work/output" && ! -s "$work/reads" ]] || fail 'unsafe credential reached external verification'
done
for task_context in 'GITHUB_ACTIONS=false' 'RUNNER_ENVIRONMENT=self-hosted'; do
  reset_fixture
  if invoke none PREBUILT_CI_AUTH_MODE=job-token PREBUILT_CI_READ_TOKEN="$fixture_token" \
    GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted "$task_context" > "$work/log" 2>&1; then fail 'accepted unsupported authentication context'; fi
  [[ ! -s "$work/output" && ! -s "$work/reads" ]] || fail 'unsupported context reached external verification'
done

# Removing recovery must reject a valid source after a transient quota refusal.
for fault in rate-transient rate-attempt-read rate-final-read rate-primary rate-both-delays rate-secondary; do
  reset_fixture
  invoke "$fault" > "$work/log" 2>&1 || fail "transient quota refusal prevented valid verification ($fault): $(cat "$work/log")"
  [[ "$(grep -c '^read$' "$work/reads")" == 4 ]] || fail 'transient refusal did not retain all three source observations'
  case "$fault" in
    rate-primary|rate-both-delays) expected_wait=2 ;;
    rate-secondary) expected_wait=60 ;;
    *) expected_wait=1 ;;
  esac
  [[ "$(cat "$work/waits")" == "$expected_wait" ]] || fail "$fault did not respect the required wait before recovery"
  grep -qx "digest=$image_digest" "$work/output" || fail 'recovered verification omitted its output'
done

# Broad retries, unbounded recovery, or accepting error response bytes must fail.
for fault in rate-persistent forbidden long-rate-limit primary-long-reset malformed-delay duplicate-delay rate-secondary-persistent rate-budget; do
  reset_fixture
  if invoke "$fault" > "$work/log" 2>&1; then fail "accepted $fault"; fi
  cmp -s "$work/before.yaml" "$work/deploy/webapp.yaml" || fail "$fault changed manifests"
  [[ ! -s "$work/output" ]] || fail "$fault exposed successful outputs"
  if [[ "$fault" == rate-persistent ]]; then
    [[ "$(grep -c '^read$' "$work/reads")" == 3 ]] || fail 'persistent quota refusal escaped the three-read bound'
    [[ "$(cat "$work/waits")" == $'1\n1' ]] || fail 'persistent refusal did not respect the advertised waits'
    grep -q 'public CI API rate limit' "$work/log" || fail 'quota exhaustion was not identified'
  elif [[ "$fault" == rate-secondary-persistent ]]; then
    [[ "$(grep -c '^read$' "$work/reads")" == 2 && "$(cat "$work/waits")" == 60 ]] || fail 'secondary retries ignored increasing backoff or the total budget'
  elif [[ "$fault" == rate-budget ]]; then
    [[ "$(grep -c '^read$' "$work/reads")" == 5 && "$(cat "$work/waits")" == $'60\n60' ]] || fail 'separate observations escaped the shared delay budget'
  else
    [[ "$(grep -c '^read$' "$work/reads")" == 1 && ! -s "$work/waits" ]] || fail "$fault was retried"
  fi
done

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
for expression in '.head_sha="wrong"' '.run_attempt=1' '.conclusion="failure"' '.status="in_progress"' '.event="pull_request"' '.head_branch="feature"' '.path=".github/workflows/other.yaml"' '.head_repository.full_name="other/app"' '.repository.full_name="other/app"' '.id=124' '.repository.private=true' '.head_repository.private=true' 'del(.repository.private)' 'del(.head_repository.private)' '.repository.private="false"' '.head_repository.private=null'; do
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
