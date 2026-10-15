#!/usr/bin/env bash
# Exercise the read-only workflow boundary and the native HTTP inspector.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
workflow="${1:-$root/.github/workflows/inspect-release-recovery.yaml}"
ci="${2:-$root/.github/workflows/ci.yaml}"
work="$(mktemp -d)"
work="$(CDPATH='' cd -- "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT
fail() { printf 'release inspection: %s\n' "$1" >&2; exit 1; }
[[ -f "$workflow" ]] || fail 'read-only workflow is missing'
yq -o=json '.' "$workflow" > "$work/workflow.json"
yq -o=json '.' "$ci" > "$work/ci.json"
jq -n --slurpfile w "$work/workflow.json" --slurpfile c "$work/ci.json" '{w:$w[0],c:$c[0]}' > "$work/bundle.json"
cat > "$work/guard.jq" <<'JQ'
  .w as $w | .c as $c | $w.jobs.inspect as $j | $j.steps as $s |
  def ordinary: .if == null and .["continue-on-error"] == null;
  ($w.permissions == {} and $j.permissions == {} and $j.if == "inputs.enable-inspection" and $j.needs == null and $j["continue-on-error"] == null) and
  $w.on.workflow_call.secrets.APP_PRIVATE_KEY.required == false and
  (["workflow_call","workflow_dispatch"] | all(. as $event |
    $w.on[$event].inputs["enable-inspection"].default == false and
    $w.on[$event].inputs["enable-inspection"].type == "boolean" and
    (["repository","tag","source-sha","run-id","run-attempt","producer-ref"] | all(. as $name |
      $w.on[$event].inputs[$name].type == "string" and $w.on[$event].inputs[$name].required == true)))) and
  ($s | length == 7 and all(ordinary)) and
  ($s[0].uses | test("^step-security/harden-runner@[a-f0-9]{40}$")) and $s[0].with["egress-policy"] == "audit" and
  $s[1].id == "admit" and
  $s[1].env.REPOSITORY == "${{ inputs.repository }}" and
  $s[1].env.CURRENT_REF == "${{ github.ref }}" and
  $s[1].env.DEFAULT_BRANCH == "${{ github.event.repository.default_branch }}" and
  ($s[1].run | contains("refs/heads/$DEFAULT_BRANCH")) and
  $s[2].id == "source" and
  $s[2].env.CATALOGUE_REPOSITORY == "${{ job.workflow_repository }}" and
  $s[2].env.CATALOGUE_SHA == "${{ job.workflow_sha }}" and
  ($s[2].run | contains("[[ \"$CATALOGUE_REPOSITORY\" == devantler-tech/.github && \"$CATALOGUE_SHA\" =~ ^[0-9a-f]{40}$ ]]")) and
  ($s[2].run | contains("env -i PATH=\"$PATH\" curl --disable")) and
  ($s[2].run | contains("https://codeload.github.com/$CATALOGUE_REPOSITORY/tar.gz/$CATALOGUE_SHA")) and
  ($s[3].uses | test("^actions/setup-go@[a-f0-9]{40}$")) and
  $s[3].with.cache == false and
  $s[4].id == "build" and
  $s[4].env == {GOWORK:"off",GOFLAGS:"",GOTOOLCHAIN:"local",CGO_ENABLED:"0"} and
  $s[4].run == "go -C .devantler-tech-inspector/.github/scripts/inspect-release-recovery build -trimpath -o \"$RUNNER_TEMP/inspect-release-recovery\" ." and
  ($s[5].uses | test("^actions/create-github-app-token@[a-f0-9]{40}$")) and
  $s[5].id == "read-token" and
  $s[5].with == {"client-id":"${{ vars.APP_CLIENT_ID }}","private-key":"${{ secrets.APP_PRIVATE_KEY }}",owner:"devantler-tech",repositories:"${{ steps.admit.outputs.name }}","permission-contents":"read","permission-actions":"read"} and
  $s[6].id == "diagnosis" and
  $s[6].env == {GH_TOKEN:"${{ steps.read-token.outputs.token }}",REPOSITORY:"${{ inputs.repository }}",TAG:"${{ inputs.tag }}",SOURCE_SHA:"${{ inputs.source-sha }}",RUN_ID:"${{ inputs.run-id }}",RUN_ATTEMPT:"${{ inputs.run-attempt }}",PRODUCER_REF:"${{ inputs.producer-ref }}"} and
  ($s[6].run | contains("\"$RUNNER_TEMP/inspect-release-recovery\"")) and
  ($s[6].run | contains("--repository \"$REPOSITORY\" --tag \"$TAG\" --source-sha \"$SOURCE_SHA\"")) and
  ($s[6].run | contains("--run-id \"$RUN_ID\" --run-attempt \"$RUN_ATTEMPT\" --producer-ref \"$PRODUCER_REF\"")) and
  ($s[6].run | contains("set -euo pipefail")) and
  ($c.jobs["test-create-release-config"].steps | any(.run == "bash .github/tests/test-inspect-release-recovery.sh" and ordinary)) and
  ($c.jobs["ci-required-checks"].needs | index("test-create-release-config") != null)
JQ
jq -e -f "$work/guard.jq" "$work/bundle.json" >/dev/null || fail 'workflow authority, provenance or required coverage is unsafe'
# shellcheck disable=SC2016 # Keep GitHub expressions literal in refusal controls.
for mutation in \
  '.w.on.workflow_call.inputs["enable-inspection"].default=true' \
  '.w.on.workflow_dispatch.inputs["enable-inspection"].default=true' \
  '.w.on.workflow_call.secrets.APP_PRIVATE_KEY.required=true' \
  '.w.jobs.inspect.if=null' \
  '.w.jobs.inspect.permissions.contents="write"' \
  '.w.jobs.inspect.steps[1].if="false"' \
  '.w.jobs.inspect.steps[2].env.CATALOGUE_SHA="main"' \
  '.w.jobs.inspect.steps[3].with.cache=true' \
  '.w.jobs.inspect.steps[4].env.GOFLAGS="-toolexec=untrusted"' \
  '.w.jobs.inspect.steps |= [.[0],.[1],.[2],.[3],.[5],.[4],.[6]]' \
  '.w.jobs.inspect.steps[5].with["permission-contents"]="write"' \
  '.w.jobs.inspect.steps[5].with.repositories=null' \
  '.w.jobs.inspect.steps[6].env.GH_TOKEN="${{ github.token }}"' \
  '.c.jobs["test-create-release-config"].steps |= map(select(.run != "bash .github/tests/test-inspect-release-recovery.sh"))'; do
  jq "$mutation" "$work/bundle.json" > "$work/mutated.json"
  if jq -e -f "$work/guard.jq" "$work/mutated.json" >/dev/null; then fail "accepted mutation: $mutation"; fi
done
# Run the actual admission block with disabled shell expansion of workflow inputs.
yq -r '.jobs.inspect.steps[1].run' "$workflow" > "$work/admit.sh"
CURRENT_REF=refs/heads/main DEFAULT_BRANCH=main REPOSITORY=devantler-tech/platform GITHUB_OUTPUT="$work/output" bash -euo pipefail "$work/admit.sh"
[[ "$(cat "$work/output")" == name=platform ]] || fail 'repository scope was not derived exactly'
for repository in 'other/repository' 'devantler-tech/.' 'devantler-tech/..' 'devantler-tech/../platform' 'devantler-tech/platform,ksail' $'devantler-tech/platform\nksail'; do
  if CURRENT_REF=refs/heads/main DEFAULT_BRANCH=main REPOSITORY="$repository" GITHUB_OUTPUT="$work/refused" bash -euo pipefail "$work/admit.sh" >/dev/null 2>&1; then fail 'unsafe repository admitted'; fi
done
if CURRENT_REF=refs/tags/v1.2.3 DEFAULT_BRANCH=main REPOSITORY=devantler-tech/platform GITHUB_OUTPUT="$work/refused" bash -euo pipefail "$work/admit.sh" >/dev/null 2>&1; then fail 'unreviewed invocation admitted'; fi
[[ ! -e "$work/refused" ]] || fail 'rejected admission emitted a repository scope'
# Execute the shipped source retrieval with a native archive and only the HTTP
# transport replaced. Ambient credentials and curl configuration must not cross
# the anonymous immutable-source boundary.
yq -r '.jobs.inspect.steps[2].run' "$workflow" > "$work/download.sh"
mkdir -p "$work/bin" "$work/archive/catalogue/.github/scripts/inspect-release-recovery" "$work/runner"
printf 'module fixture\n\ngo 1.23.0\n' > "$work/archive/catalogue/.github/scripts/inspect-release-recovery/go.mod"
printf 'package main\nfunc main() {}\n' > "$work/archive/catalogue/.github/scripts/inspect-release-recovery/main.go"
tar -czf "$work/valid.tar.gz" -C "$work/archive" catalogue
cat > "$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
fixture="$(cd "$(dirname "$0")/.." && pwd -P)"
printf 'request\n' >> "$fixture/transport-used"
[[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${CURL_HOME-}${HTTPS_PROXY-}" ]]
expected=(--disable --fail --silent --show-error --location
  --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 --retry 3
  --output "$fixture/runner/inspector.tar.gz"
  'https://codeload.github.com/devantler-tech/.github/tar.gz/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
[[ "$#" == "${#expected[@]}" ]]
index=0
for arg in "$@"; do [[ "$arg" == "${expected[index]}" ]]; index=$((index+1)); done
cp "$fixture/payload.tar.gz" "$fixture/runner/inspector.tar.gz"
CURL
chmod +x "$work/bin/curl"
cp "$work/valid.tar.gz" "$work/payload.tar.gz"
mkdir "$work/download"
(
  cd "$work/download"
  PATH="$work/bin:$PATH" RUNNER_TEMP="$work/runner" CATALOGUE_REPOSITORY=devantler-tech/.github \
    CATALOGUE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GH_TOKEN=must-not-forward \
    CURL_HOME=must-not-forward HTTPS_PROXY=must-not-forward bash -euo pipefail "$work/download.sh"
)
[[ -f "$work/download/.devantler-tech-inspector/.github/scripts/inspect-release-recovery/main.go" ]] || fail 'inspector was not retrieved'
rm "$work/transport-used"
for invalid in source repository; do
  mkdir "$work/invalid-$invalid"
  catalogue_repository=devantler-tech/.github catalogue_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if [[ "$invalid" == source ]]; then catalogue_sha=main; else catalogue_repository=other/catalogue; fi
  if (
    cd "$work/invalid-$invalid"
    PATH="$work/bin:$PATH" RUNNER_TEMP="$work/runner" CATALOGUE_REPOSITORY="$catalogue_repository" \
      CATALOGUE_SHA="$catalogue_sha" bash -euo pipefail "$work/download.sh" > "$work/refused-source" 2>&1
  ); then fail 'untrusted inspector source accepted'; fi
  [[ ! -e "$work/transport-used" ]] || fail 'invalid catalogue source reached the network'
done
rm "$work/archive/catalogue/.github/scripts/inspect-release-recovery/main.go"
tar -czf "$work/payload.tar.gz" -C "$work/archive" catalogue
mkdir "$work/incomplete"
if (
  cd "$work/incomplete"
  PATH="$work/bin:$PATH" RUNNER_TEMP="$work/runner" CATALOGUE_REPOSITORY=devantler-tech/.github \
    CATALOGUE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bash -euo pipefail "$work/download.sh" > "$work/refused-download" 2>&1
); then fail 'incomplete immutable source accepted'; fi
[[ "${3:-}" != --guard-only ]] || exit 0
GOWORK=off GOFLAGS='' GOTOOLCHAIN=local go -C "$root/.github/scripts/inspect-release-recovery" test -race -count=1 ./...
GOWORK=off GOFLAGS='' GOTOOLCHAIN=local go -C "$root/.github/scripts/inspect-release-recovery" vet ./...
printf '%s\n' 'PASS: default-off read-only inspection, scoped authority, immutable source and native HTTP refusals'
