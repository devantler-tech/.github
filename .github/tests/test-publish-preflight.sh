#!/usr/bin/env bash

# Pins #263: the two publish workflows refuse a bad release BEFORE their first registry write.
#   - publish-app.yaml checks the deployment manifest (file present, exactly one container named
#     `app-name`) before the image push, so a bad manifest leaves GHCR untouched — `latest` included.
#     The digest is still injected after the build, because it does not exist before it.
#   - Both workflows accept only a complete SemVer 2.0.0 tag behind a `v` (optional pre-release and
#     build metadata), so `v1.2.3garbage` is refused instead of being published as `1.2.3garbage`.
#     Build metadata is dropped from the published version, because an OCI tag cannot carry `+`.
#
# "Nothing pushed" is OBSERVED, not inferred from step order: each workflow's publish job runs here
# in its shipped step order. Every `run:` step executes as extracted from the workflow, with its own
# `env:` resolved from the job's real expressions; every `uses:` step must be a known action — the
# image push (docker/build-push-action with push) is recorded as a registry write, the rest are
# setup no-ops. Stub `flux`, `cosign` and `docker` binaries record every registry call; run steps
# see only those stubs and a fixed set of tools that cannot publish; and a failing step stops the
# job as it does on a runner. Anything the simulation does not model — an unknown action, tool,
# expression, step condition, shell, env or output form, or a workflow, job or step key such as
# `continue-on-error` that would make a runner behave differently — fails this test rather than
# being ignored.

# shellcheck disable=SC2016 # `$in`, `$J`, `$S` and `${{ }}` are jq and GitHub syntax, not shell.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d)"
repo_root="$(pwd)"
trap 'rm -rf "$scratch"' EXIT

sha40="0123456789abcdef0123456789abcdef01234567"
image_digest="sha256:$(printf 'b%.0s' $(seq 1 64))"
artifact_digest="sha256:$(printf 'a%.0s' $(seq 1 64))"

mkdir -p "$scratch/bin"
cat >"$scratch/bin/flux" <<'EOF'
#!/usr/bin/env bash
printf 'flux %s\n' "$*" >>"$CALLS"
if [[ "$1 $2" == "push artifact" ]]; then
  printf '{"digest":"%s"}\n' "$STUB_ARTIFACT_DIGEST"
fi
EOF
cat >"$scratch/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"$CALLS"
EOF
cat >"$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$CALLS"
for arg in "$@"; do
  if [[ "$arg" == --metadata-file=* ]]; then
    printf '{"containerimage.descriptor":{"digest":"%s"}}\n' "$STUB_IMAGE_DIGEST" >"${arg#*=}"
  fi
done
printf '%s\n' "$STUB_ARTIFACT_DIGEST"
EOF
cp .github/tests/fixtures/registry-read-curl.sh "$scratch/bin/registry-curl"
chmod +x "$scratch/bin/registry-curl"
cat >"$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -q ]]; then exec registry-curl "$@"; fi
[[ "$#" == 6 && "$1" == -fsS && "$2" == --max-time && "$3" =~ ^[1-9][0-9]*$ && \
  "$4" == -H && "$5" == "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" && \
  "$6" == "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sigstore" ]] || {
  echo 'unmodelled token request' >&2
  exit 1
}
printf 'oidc request\n' >>"$OIDC_CALLS"
cat "$OIDC_FIXTURE"
EOF
chmod +x "$scratch/bin/flux" "$scratch/bin/cosign" "$scratch/bin/docker" "$scratch/bin/curl"

# A token-shaped URL must not make an arbitrary curl upload invisible to the no-write model.
printf '{"value":"probe"}\n' >"$scratch/probe-token.json"
if OIDC_FIXTURE="$scratch/probe-token.json" OIDC_CALLS="$scratch/probe-oidc-calls" \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=stub-not-a-secret ACTIONS_ID_TOKEN_REQUEST_URL=https://oidc.invalid/token \
  "$scratch/bin/curl" -fsS --max-time 10 -H 'Authorization: bearer stub-not-a-secret' \
    'https://oidc.invalid/token&audience=sigstore' --data '{}' >/dev/null 2>&1; then
  fail 'the token stub accepted an unmodelled network upload'
fi

# ---- the simulated job ------------------------------------------------------------------------

# Run steps see ONLY the stubs and this explicit set of tools, none of which can write to a registry.
# A step that reaches for anything else — oras, crane, gh — fails loudly instead of writing
# where the no-push assertions below cannot see it. Add a tool here only if it cannot publish.
mkdir -p "$scratch/tools"
for tool in base64 bash cat cp cut grep head jq mkdir mktemp rm sed sort tail tr wc yq; do
  tool_path="$(command -v "$tool")" || fail "this test needs $tool on PATH"
  ln -s "$tool_path" "$scratch/tools/$tool"
done
step_path="$scratch/bin:$scratch/tools"

# Per-run state, reset by run_job.
sim_workflow=""
sim_json="" # the workflow under simulation as JSON, converted once per file
sim_job=""
sim_step=""
sim_ref_type=""
sim_ref_name=""
sim_repository=""
sim_inputs="$scratch/inputs"   # name=value, the caller's `with:`
sim_outputs="$scratch/outputs" # <step-id>.<name>=value, from GITHUB_OUTPUT
calls="$scratch/calls"         # every registry call, in order
log="$scratch/log"             # the output of every step that ran

wf() { # <jq expression> [jq args...] — evaluated on the whole workflow
  local expr="$1"
  shift
  jq -r "$@" "$expr" "$sim_json"
}

in_job() { # <jq expression> — evaluated with $J bound to the simulated job and $S to its current step
  jq -r --arg job "$sim_job" --argjson i "${sim_step:-0}" \
    ".jobs[\$job] as \$J | \$J.steps[\$i] as \$S | $1" "$sim_json"
}

step() { # <jq expression> — evaluated on the current step of the simulated job
  in_job "\$S | $1"
}

lookup_line() { # <file> <key> — prints the value of the first `key=value` line; 1 when absent
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line%%=*}" == "$2" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$1"
  return 1
}

lookup_expr() { # <expression> — the value GitHub would substitute for ${{ <expression> }}
  local input id
  case "$1" in
    github.ref_type) printf '%s' "$sim_ref_type" ;;
    github.ref_name) printf '%s' "$sim_ref_name" ;;
    github.sha) printf '%s' "$sha40" ;;
    github.run_id) printf '%s' 123 ;;
    github.run_attempt) printf '%s' 2 ;;
    github.server_url) printf '%s' "https://github.com" ;;
    github.repository) printf '%s' "$sim_repository" ;;
    github.actor) printf '%s' "bot" ;;
    job.workflow_repository) printf '%s' 'devantler-tech/.github' ;;
    job.workflow_sha) printf '%s' "$sha40" ;;
    secrets.GITHUB_TOKEN) printf '%s' "stub-not-a-secret" ;;
    env.*) lookup_line "$scratch/job-env" "${1#env.}" ;;
    inputs.*)
      case "$1" in
        "inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == 'true'")
          [[ "$(lookup_expr inputs.enable-signed-promotion)" == true ]] && printf true || printf false
          return 0
          ;;
      esac
      input="${1#inputs.}"
      [[ "$(wf '.on.workflow_call.inputs | has($in)' --arg in "$input")" == true ]] || return 1
      # Passed by the caller (even as an empty string) wins; otherwise the declared default applies.
      # A required input that was not passed never reaches a step: a runner refuses the call.
      lookup_line "$sim_inputs" "$input" && return 0
      if [[ "$(wf '.on.workflow_call.inputs[$in].required // false' --arg in "$input")" == true ]]; then
        echo "required input '$input' was not passed to $sim_workflow" >&2
        return 1
      fi
      wf '.on.workflow_call.inputs[$in] | select(has("default")) | .default' --arg in "$input"
      ;;
    steps.*.outputs.*)
      id="${1#steps.}"
      id="${id%%.outputs.*}"
      # An output the step never set is the empty string on a runner.
      lookup_line "$sim_outputs" "${id}.${1##*.outputs.}" || true
      ;;
    "!(inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == 'true')")
      [[ "$(lookup_expr inputs.enable-signed-promotion)" != true ]] && printf true || printf false
      ;;
    "!inputs.enable-signed-recovery")
      [[ "$(lookup_expr inputs.enable-signed-recovery)" != true ]] && printf true || printf false
      ;;
    "!inputs.enable-signed-recovery && (inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == 'true')")
      [[ "$(lookup_expr inputs.enable-signed-recovery)" != true && "$(lookup_expr inputs.enable-signed-promotion)" == true ]] && printf true || printf false
      ;;
    "(inputs.enable-signed-promotion == true || inputs.enable-signed-promotion == 'true') && steps.staging.outputs.tag || steps.meta.outputs.tags")
      if [[ "$(lookup_expr inputs.enable-signed-promotion)" == true ]]; then
        lookup_expr steps.staging.outputs.tag
      else
        lookup_expr steps.meta.outputs.tags
      fi
      ;;
    *) return 1 ;;
  esac
}

resolve() { # <string> — substitutes every ${{ ... }} expression, failing on an unmodelled one
  # shellcheck disable=SC2016 # the literal GitHub expression delimiter, not a shell expansion.
  local s="$1" out="" expr rest value open='${{' close='}}'
  while [[ "$s" == *"$open"* ]]; do
    out+="${s%%"$open"*}"
    rest="${s#*"$open"}"
    [[ "$rest" == *"$close"* ]] || return 1
    expr="${rest%%"$close"*}"
    s="${rest#*"$close"}"
    expr="${expr#"${expr%%[![:space:]]*}"}"
    expr="${expr%"${expr##*[![:space:]]}"}"
    value="$(lookup_expr "$expr")" || {
      echo "unmodelled expression '\${{ $expr }}' in $sim_workflow — extend lookup_expr" >&2
      return 1
    }
    out+="$value"
  done
  printf '%s' "$out$s"
}

env_entries() { # <jq path to an env mapping> — one key=value line per entry, values as strings
  local entries
  # GitHub turns a non-string value (`DRY_RUN: false`) into its string; a multi-line value cannot
  # be carried as one line, so refuse it rather than misread it.
  [[ "$(in_job "$1 // {} | [.[] | tostring | select(contains(\"\\n\"))] | length")" == 0 ]] ||
    fail "$sim_workflow carries a multi-line env value at $1, which this test does not model"
  entries="$(in_job "$1 // {} | to_entries[] | .key + \"=\" + (.value | tostring)")" ||
    fail "could not read the env at $1 in $sim_workflow"
  printf '%s' "$entries"
}

# run_job <workflow> <job> <workdir> <ref-type> <ref-name> [input=value ...]
# Runs the job's steps in order in <workdir>, as repository $SIM_REPOSITORY (default
# devantler-tech/app). Returns 0 when every step passed, 1 when a step failed (the job stops
# there). Exits the test on anything the simulation does not model.
run_job() {
  sim_workflow="$1"
  sim_job="$2"
  local workdir="$3" count i name if_expr if_value uses action run_file push id status tags
  sim_ref_type="$4"
  sim_ref_name="$5"
  sim_repository="${SIM_REPOSITORY:-devantler-tech/app}"
  sim_step=""
  shift 5
  : >"$sim_inputs"
  : >"$sim_outputs"
  : >"$calls"
  : >"$log"
  : >"$scratch/oidc-calls"
  local oidc_payload
  oidc_payload="$(jq -nc --arg ref "${SIM_CALLER_REF:-devantler-tech/.github/$sim_workflow@$sha40}" \
    '{job_workflow_ref:$ref}' | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  printf '{"value":"header.%s.signature"}\n' "$oidc_payload" >"$scratch/oidc-token.json"
  local pair line unmodelled entries
  for pair in "$@"; do printf '%s\n' "$pair" >>"$sim_inputs"; done
  sim_json="$scratch/$(basename "$sim_workflow").json"
  [[ -s "$sim_json" ]] || yq -o=json '.' "$sim_workflow" >"$sim_json" || fail "could not read $sim_workflow"

  # Anything that changes how a step or the job behaves on a runner — workflow-level env or
  # defaults, a second job running alongside, continue-on-error, a matrix, a job condition other
  # than the dry-run gate the simulation honours — is refused rather than ignored, so the
  # simulation cannot pass on a workflow that a runner would run differently.
  unmodelled="$(wf 'keys | map(select(. != "name" and . != "run-name" and . != "on"
    and . != "permissions" and . != "concurrency" and . != "jobs")) | join(" ")')"
  [[ -z "$unmodelled" ]] || fail "$sim_workflow sets $unmodelled at workflow level; model it"
  [[ "$(wf '.jobs | keys | join(" ")')" == "$sim_job" ]] ||
    fail "$sim_workflow runs jobs besides $sim_job, which could publish while it refuses; model them"
  unmodelled="$(in_job '$J | keys | map(select(. != "name" and . != "if" and . != "runs-on"
    and . != "permissions" and . != "env" and . != "steps" and . != "concurrency")) | join(" ")')"
  [[ -z "$unmodelled" ]] ||
    fail "$sim_workflow job $sim_job sets $unmodelled, which this test does not model"
  # Both publisher modes serialize one target without replacing pending releases.
  local concurrency_group
  case "$sim_job" in
    publish) concurrency_group='${{ format('\''publish-verified-{0}'\'', github.repository) }}' ;;
    publish-manifests) concurrency_group='${{ format('\''publish-verified-{0}'\'', inputs.oci-name || github.repository) }}' ;;
    *) fail 'unmodelled publication concurrency group' ;;
  esac
  [[ "$(in_job '$J.concurrency | keys | sort | join(" ")')" == 'cancel-in-progress group queue' &&
     "$(in_job '$J.concurrency.group')" == "$concurrency_group" &&
     "$(in_job '$J.concurrency.queue')" == max &&
     "$(in_job '$J.concurrency["cancel-in-progress"]')" == false ]] ||
    fail "$sim_workflow does not serialize verified publication without canceling releases"
  # shellcheck disable=SC2016 # GitHub expression compared literally.
  [[ "$(in_job '$J.if // ""')" == '${{ !inputs.dry-run }}' ]] ||
    fail "$sim_workflow job $sim_job is no longer gated exactly on the dry-run input; model its condition"
  [[ "$(lookup_expr inputs.dry-run)" == false ]] || fail "the simulated job must run with dry-run off"

  # Job-level env, resolved once, reaches every run step.
  : >"$scratch/job-env"
  local job_env=() key value shell_flags
  entries="$(env_entries '$J.env')"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    value="$(resolve "${line#*=}")" || fail "could not resolve $sim_job job env $key"
    printf '%s=%s\n' "$key" "$value" >>"$scratch/job-env"
    job_env+=("$key=$value")
  done <<<"$entries"

  count="$(in_job '$J.steps | length')"
  [[ "$count" -gt 0 ]] || fail "$sim_workflow job $sim_job has no steps"

  for ((i = 0; i < count; i++)); do
    sim_step="$i"
    name="$(step '.name // ""')"
    id="$(step '.id // ""')"

    unmodelled="$(step 'keys | map(select(. != "name" and . != "id" and . != "if" and . != "uses"
      and . != "with" and . != "env" and . != "run" and . != "shell")) | join(" ")')"
    [[ -z "$unmodelled" ]] ||
      fail "$sim_workflow step '$name' sets $unmodelled, which this test does not model"

    if_expr="$(step '.if // ""')"
    if [[ -n "$if_expr" ]]; then
      if_value="$(resolve "$if_expr")" || fail "could not resolve the condition on '$name'"
      case "$if_value" in
        true) ;;
        false | "") continue ;;
        *) fail "$sim_workflow step '$name' has a condition this test does not model: $if_expr" ;;
      esac
    fi

    uses="$(step '.uses // ""')"
    if [[ -n "$uses" ]]; then
      action="${uses%%@*}"
      case "$action" in
        step-security/harden-runner | actions/checkout | docker/login-action | \
          docker/metadata-action | fluxcd/flux2/action | sigstore/cosign-installer)
          # A setup step can fail on its own (a download, a login), and failing after the first
          # registry write leaves a release half-published, so every one must come before it.
          [[ ! -s "$calls" ]] ||
            fail "$sim_workflow step '$name' sets up $action after the first registry write"
          printf 'setup %s\n' "$action" >>"$log"
          if [[ "$action" == actions/checkout && "$(step '.with.path // ""')" == .devantler-tech-publisher ]]; then
            [[ "$(resolve "$(step '.with.repository')")" == devantler-tech/.github &&
              "$(resolve "$(step '.with.ref')")" == "$sha40" ]] || fail 'helper checkout does not select immutable publisher source'
            mkdir -p "$workdir/.devantler-tech-publisher/.github/scripts"
            cp "$repo_root/.github/scripts/require-unpublished-version.sh" \
              "$repo_root/.github/scripts/recover-app-version.sh" "$repo_root/.github/scripts/recover-manifests-version.sh" \
              "$workdir/.devantler-tech-publisher/.github/scripts/"
          fi
          if [[ "$action" == docker/metadata-action ]]; then
            printf '%s.tags=ghcr.io/%s:%s\n' "$id" "$(printf '%s' "$sim_repository" | tr '[:upper:]' '[:lower:]')" \
              "$(lookup_expr steps.version.outputs.version)" >>"$sim_outputs"
          fi
          ;;
        docker/build-push-action)
          push="$(step '.with.push // false | tostring')"
          [[ "$push" == "true" ]] || fail "$sim_workflow '$name' builds without pushing; model it"
          printf 'image push %s\n' "$name" >>"$calls"
          # Observe the selected build references, including conditional staging.
          # A build that leaks a version/latest alias must be visible to this model.
          tags="$(resolve "$(step '.with.tags')")" || fail 'unmodelled build tags'
          printf 'image tags %s\n' "$tags" >>"$calls"
          [[ -z "$id" ]] || printf '%s.digest=%s\n' "$id" "$image_digest" >>"$sim_outputs"
          ;;
        *) fail "$sim_workflow step '$name' uses $action, which this test does not model; classify it" ;;
      esac
      continue
    fi

    run_file="$scratch/step-$i.sh"
    step '.run // ""' >"$run_file.body"
    [[ -s "$run_file.body" ]] || fail "$sim_workflow step '$name' has neither uses nor run"
    # Bash 4+ calls this hook for every command it cannot find, so even `oras push 2>/dev/null ||
    # true` is recorded; on bash 3.2 the `command not found` message below is the fallback.
    {
      # shellcheck disable=SC2016 # written into the step script, expanded when the step runs.
      printf '%s\n' 'command_not_found_handle() { printf "%s\n" "$*" >>"$UNMODELLED"; return 127; }'
      cat "$run_file.body"
    } >"$run_file"

    # The runner's own invocations: an unspecified shell is `bash -e {0}`, an explicit `bash` adds
    # pipefail. Any other shell is not modelled.
    case "$(step '.shell // ""')" in
      "") shell_flags=(-e) ;;
      bash) shell_flags=(-e -o pipefail) ;;
      *) fail "$sim_workflow step '$name' uses a shell this test does not model" ;;
    esac

    local step_env=()
    entries="$(env_entries '$S.env')"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key="${line%%=*}"
      value="$(resolve "${line#*=}")" || fail "could not resolve env $key on '$name'"
      step_env+=("$key=$value")
    done <<<"$entries"

    : >"$scratch/github-output"
    : >"$scratch/unmodelled"
    printf '== %s\n' "$name" >>"$log"
    status=0
    (cd "$workdir" && env -i PATH="$step_path" HOME="$HOME" TMPDIR="$scratch" \
      CALLS="$calls" UNMODELLED="$scratch/unmodelled" STUB_ARTIFACT_DIGEST="$artifact_digest" \
      STUB_IMAGE_DIGEST="$image_digest" RUNNER_TEMP="$scratch" GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 \
      GITHUB_OUTPUT="$scratch/github-output" \
      OIDC_FIXTURE="$scratch/oidc-token.json" OIDC_CALLS="$scratch/oidc-calls" \
      ACTIONS_ID_TOKEN_REQUEST_URL="https://oidc.invalid/token" \
      ACTIONS_ID_TOKEN_REQUEST_TOKEN="stub-not-a-secret" \
      ${job_env[@]+"${job_env[@]}"} ${step_env[@]+"${step_env[@]}"} \
      "$scratch/tools/bash" --noprofile --norc "${shell_flags[@]}" "$run_file") \
      >"$scratch/step.log" 2>&1 || status=$?
    cat "$scratch/step.log" >>"$log"
    # A command outside the stubs and the tool set could have published on a real runner, even
    # behind `|| true`, so it fails this test however the step ended. (A command run by absolute
    # path bypasses PATH and is outside what this simulation can see; no step does that.)
    if [[ -s "$scratch/unmodelled" ]] || grep -qF 'command not found' "$scratch/step.log"; then
      fail "$sim_workflow step '$name' runs a command this test does not model: $(cat "$scratch/unmodelled" "$scratch/step.log")"
    fi
    if [[ "$status" -ne 0 ]]; then
      printf 'FAILED at %s\n' "$name" >>"$log"
      return 1
    fi
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      [[ "$line" == *=* && "${line%%=*}" != *"<<"* ]] ||
        fail "$sim_workflow step '$name' writes an output this test does not model: $line"
      if [[ -n "$id" ]]; then
        printf '%s.%s\n' "$id" "$line" >>"$sim_outputs"
      fi
    done <"$scratch/github-output"
  done
  return 0
}

nothing_pushed() { # <label>
  [[ ! -s "$calls" ]] || fail "$1 reached the registry before refusing: $(cat "$calls"); log: $(cat "$log")"
}

refused_with() { # <label> <expected message fragment>
  grep -qF -- "$2" "$log" || fail "$1 failed, but not with '$2'; log: $(cat "$log")"
}

# ---- fixtures ---------------------------------------------------------------------------------

new_app() { # <dir> — a checkout whose ./deploy/deployment.yaml carries exactly one `app` container
  mkdir -p "$1/deploy"
  cat >"$1/deploy/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  template:
    spec:
      containers:
        - name: app
          image: ghcr.io/devantler-tech/app:placeholder
        - name: sidecar
          image: ghcr.io/devantler-tech/sidecar:1.0.0
EOF
}

app=.github/workflows/publish-app.yaml
manifests=.github/workflows/publish-manifests.yaml
[[ -f "$app" && -f "$manifests" ]] || fail "run from the repository root"

# ---- 0. the simulation catches a command outside its tool set, even silenced ------------------

# The hook that records it needs bash 4+, which CI runs; macOS's bash 3.2 has only the visible
# `command not found` message, so there the silenced case is skipped rather than claimed.
if [[ "$("$scratch/tools/bash" -c 'echo "${BASH_VERSINFO[0]}"')" -ge 4 ]]; then
  probe="$scratch/probe.yaml"
  yq '.jobs.publish.steps = [{"name": "sneaky", "run": "oras push ghcr.io/x:1 2>/dev/null || true"}]' \
    "$app" >"$probe"
  if out="$(run_job "$probe" publish "$scratch" tag v1.2.3 2>&1)"; then
    fail "the simulation ran a silenced command outside its tool set without noticing"
  fi
  [[ "$out" == *"runs a command this test does not model"* ]] ||
    fail "the simulation refused the probe for the wrong reason: $out"
  echo "ok   the simulation catches a silenced command outside its tool set"
else
  echo "skip the silenced-command probe needs bash 4+ (CI runs it)"
fi

# ---- 1. publish-app: a good release pushes, and pins the digest after the build -----------------

wd="$scratch/app-good"
new_app "$wd"
run_job "$app" publish "$wd" tag v1.2.3 app-name=app ||
  fail "publish-app failed a good release: $(cat "$log")"
grep -qxF "image push 🐳 Build & push image" "$calls" ||
  fail "publish-app never pushed the image; calls: $(cat "$calls")"
grep -qF "image tags ghcr.io/devantler-tech/app:staging-123-2" "$calls" ||
  fail "publish-app did not stage the image before signing; calls: $(cat "$calls")"
grep -qF "flux push artifact oci://ghcr.io/devantler-tech/app/manifests:default-staging-123-2 " "$calls" ||
  fail "publish-app did not stage the manifests before signing; calls: $(cat "$calls")"
grep -qF "flux tag artifact oci://ghcr.io/devantler-tech/app/manifests@$artifact_digest --tag 1.2.3 " "$calls" ||
  fail "publish-app did not promote its signed manifests digest as 1.2.3; calls: $(cat "$calls")"
pinned="$(yq '.spec.template.spec.containers[] | select(.name == "app") | .image' \
  "$wd/deploy/deployment.yaml")"
[[ "$pinned" == "ghcr.io/devantler-tech/app@$image_digest" ]] ||
  fail "publish-app did not inject the built digest into the manifest; got: $pinned"
first_write="$(head -n 1 "$calls")"
[[ "$first_write" == "image push 🐳 Build & push image" ]] ||
  fail "publish-app's first registry write is not the image push: $first_write"
echo "ok   publish-app publishes a good release and injects the digest after the build"

# Both publishers run their actual OIDC resolver and admission guard by default. A moving ref
# must fail before checkout or registry activity; explicit false preserves the rollout interface.
for workflow in "$app" "$manifests"; do
  job=publish
  [[ "$workflow" == "$app" ]] || job=publish-manifests
  for setting in omitted true false; do
    wd="$scratch/pin-$job-$setting"
    new_app "$wd"
    passed=(app-name=app)
    [[ "$workflow" == "$app" ]] || passed=()
    [[ "$setting" == omitted ]] || passed+=("enable-caller-pin=$setting")
    run_job "$workflow" "$job" "$wd" tag v1.2.3 ${passed[@]+"${passed[@]}"} ||
      fail "$workflow failed a good $setting caller-pin release: $(cat "$log")"
    if [[ "$setting" == false ]]; then
      [[ ! -s "$scratch/oidc-calls" ]] || fail "$workflow explicit false requested OIDC"
      ! grep -qF '== 🔒 Require a SHA-pinned caller' "$log" ||
        fail "$workflow explicit false ran the pin guard"
    else
      grep -qxF 'oidc request' "$scratch/oidc-calls" ||
        fail "$workflow $setting input did not request OIDC"
      grep -qF '== 🔒 Require a SHA-pinned caller' "$log" ||
        fail "$workflow $setting input did not run the pin guard"
      if SIM_CALLER_REF="devantler-tech/.github/$workflow@refs/heads/main" \
        run_job "$workflow" "$job" "$wd" tag v1.2.3 ${passed[@]+"${passed[@]}"}; then
        fail "$workflow $setting input accepted a moving caller ref"
      fi
      nothing_pushed "$workflow $setting moving ref"
      refused_with "$workflow $setting moving ref" 'must be called by a 40-character commit SHA'
      ! grep -qF 'setup actions/checkout' "$log" ||
        fail "$workflow $setting moving ref reached checkout"
    fi
  done
done
echo 'ok   both publishers enforce omitted/true pin inputs before checkout and preserve explicit false'

# Explicit recovery must never fall through to a legacy writer when either
# admission prerequisite is disabled. Execute the shipped guard in job order.
for workflow in "$app" "$manifests"; do
  job=publish
  [[ "$workflow" == "$app" ]] || job=publish-manifests
for prerequisites in 'enable-signed-promotion=false enable-caller-pin=true' 'enable-signed-promotion=true enable-caller-pin=false' 'enable-signed-promotion=false enable-caller-pin=false'; do
  wd="$scratch/recovery-refused"
  mkdir -p "$wd"
  # shellcheck disable=SC2086 # fixed input pairs, not content from a repository
  if run_job "$workflow" "$job" "$wd" tag v1.2.3 app-name=app enable-signed-recovery=true $prerequisites; then
    fail 'recovery bypassed signed-promotion/caller admission'
  fi
  nothing_pushed 'recovery without its prerequisites'
  refused_with 'recovery without its prerequisites' 'recovery requires signed promotion and caller pinning'
done
done
echo 'ok   explicit recovery cannot fall through to legacy publication'

# A repository name with uppercase letters: docker/metadata-action lowercases the image it pushes,
# so the pinned reference and the manifests path must be lowercase too, or the push after the
# image fails on an invalid reference.
wd="$scratch/app-uppercase"
new_app "$wd"
SIM_REPOSITORY=devantler-tech/MyApp run_job "$app" publish "$wd" tag v1.2.3 app-name=app ||
  fail "publish-app failed a good release from an uppercase repository name: $(cat "$log")"
grep -qF "flux push artifact oci://ghcr.io/devantler-tech/myapp/manifests:default-staging-123-2 " "$calls" ||
  fail "publish-app did not push the manifests under a lowercase path; calls: $(cat "$calls")"
pinned="$(yq '.spec.template.spec.containers[] | select(.name == "app") | .image' \
  "$wd/deploy/deployment.yaml")"
[[ "$pinned" == "ghcr.io/devantler-tech/myapp@$image_digest" ]] ||
  fail "publish-app pinned a reference that is not lowercase: $pinned"
SIM_REPOSITORY=devantler-tech/MyApp run_job "$manifests" publish-manifests "$wd" tag v1.2.3 ||
  fail "publish-manifests failed a good release from an uppercase repository name: $(cat "$log")"
grep -qF "flux push artifact oci://ghcr.io/devantler-tech/myapp/manifests:default-staging-123-2 " "$calls" ||
  fail "publish-manifests did not push under a lowercase path; calls: $(cat "$calls")"
echo "ok   both workflows publish an uppercase repository name under lowercase references"

# ---- 2. publish-app: a bad manifest pushes nothing ---------------------------------------------

wd="$scratch/app-missing"
mkdir -p "$wd"
if run_job "$app" publish "$wd" tag v1.2.3 app-name=app; then
  fail "publish-app succeeded with no deployment manifest"
fi
nothing_pushed "publish-app with no manifest"
refused_with "publish-app with no manifest" "manifest ./deploy/deployment.yaml not found"

wd="$scratch/app-wrong-path"
new_app "$wd"
if run_job "$app" publish "$wd" tag v1.2.3 app-name=app deploy-path=./k8s; then
  fail "publish-app succeeded with a deploy-path that holds no manifest"
fi
nothing_pushed "publish-app with a wrong deploy-path"
refused_with "publish-app with a wrong deploy-path" "manifest ./k8s/deployment.yaml not found"

wd="$scratch/app-no-match"
new_app "$wd"
if run_job "$app" publish "$wd" tag v1.2.3 app-name=api; then
  fail "publish-app succeeded although no container matches app-name"
fi
nothing_pushed "publish-app with no matching container"
refused_with "publish-app with no matching container" "expected exactly one container named 'api'"

wd="$scratch/app-duplicate"
new_app "$wd"
yq -i '.spec.template.spec.containers[1].name = "app"' "$wd/deploy/deployment.yaml"
if run_job "$app" publish "$wd" tag v1.2.3 app-name=app; then
  fail "publish-app succeeded although two containers match app-name"
fi
nothing_pushed "publish-app with two matching containers"
refused_with "publish-app with two matching containers" "found 2"

wd="$scratch/app-unparsable"
new_app "$wd"
printf 'spec: [unterminated\n' >"$wd/deploy/deployment.yaml"
if run_job "$app" publish "$wd" tag v1.2.3 app-name=app; then
  fail "publish-app succeeded with an unparsable manifest"
fi
nothing_pushed "publish-app with an unparsable manifest"
refused_with "publish-app with an unparsable manifest" "FAILED at 🔍 Validate the deployment manifest"
echo "ok   publish-app refuses a bad manifest before pushing anything"

# ---- 3. both workflows: only a complete semantic-version tag publishes --------------------------

# tag|published version. SemVer 2.0.0 examples, including its own edge cases.
accepted=(
  "v0.0.0|0.0.0"
  "v1.2.3|1.2.3"
  "v10.20.30|10.20.30"
  "v1.2.3-rc.1|1.2.3-rc.1"
  "v1.0.0-alpha.beta.1|1.0.0-alpha.beta.1"
  "v1.0.0-0A.is.legal|1.0.0-0A.is.legal"
  "v1.0.0-x-y-z.--|1.0.0-x-y-z.--"
  "v1.2.3+build.5|1.2.3"
  "v1.2.3-rc.1+build.5|1.2.3-rc.1"
  "v1.0.0+0.build.1-rc.10000aaa-kk-0.1|1.0.0"
  "v999999999999999.0.0|999999999999999.0.0"
  "v1.2.3-rc.999999999999999|1.2.3-rc.999999999999999"
  "v1.2.3-1234567890123456a|1.2.3-1234567890123456a"
)
long_pre="$(printf 'a%.0s' $(seq 1 130))"
long_build="$(printf 'b%.0s' $(seq 1 251))"
rejected=(
  "v1.2.3garbage"
  "v1.2.3.4"
  "v1.2"
  "v1"
  "1.2.3"
  "V1.2.3"
  "v01.2.3"
  "v1.02.3"
  "v1.2.03"
  "v1.2.3-"
  "v1.2.3+"
  "v1.2.3-01"
  "v1.2.3-rc..1"
  "v1.2.3-rc.1+"
  "v1.2.3+build..1"
  "v1.2.3_build"
  "v1.2.3 "
  " v1.2.3"
  "v1.2.3-ünicode"
  "v1.2.3-${long_pre}"
  # Valid SemVer that docker/metadata-action (numbers below 2^53, 256 characters) or Flux (numbers
  # below 2^64) cannot read, so the image or the manifests would miss their version.
  "v9007199254740992.0.0"
  "v1.0.18446744073709551616"
  "v1.2.3-rc.1000000000000000"
  "v1.2.3+${long_build}"
)

tag_step="🔒 Require a semantic-version tag"
for workflow in "$app" "$manifests"; do
  job="$(yq -r '.jobs | keys | .[0]' "$workflow")"
  # Only publish-app declares app-name; pass each workflow just the inputs it declares.
  with=()
  [[ "$workflow" != "$app" ]] || with=(app-name=app)

  for entry in "${accepted[@]}"; do
    tag="${entry%%|*}"
    want="${entry#*|}"
    wd="$scratch/tag-ok"
    rm -rf "$wd"
    new_app "$wd"
    run_job "$workflow" "$job" "$wd" tag "$tag" ${with[@]+"${with[@]}"} ||
      fail "$workflow refused the valid tag $tag: $(cat "$log")"
    grep -qF "flux tag artifact oci://ghcr.io/devantler-tech/app/manifests@$artifact_digest --tag ${want} " "$calls" ||
      fail "$workflow did not publish $tag as $want; calls: $(cat "$calls")"
  done

  for tag in "${rejected[@]}"; do
    wd="$scratch/tag-bad"
    rm -rf "$wd"
    new_app "$wd"
    if run_job "$workflow" "$job" "$wd" tag "$tag" ${with[@]+"${with[@]}"}; then
      fail "$workflow published the malformed tag '$tag'; calls: $(cat "$calls")"
    fi
    nothing_pushed "$workflow with the malformed tag '$tag'"
    refused_with "$workflow with the malformed tag '$tag'" "FAILED at $tag_step"
  done

  # A branch named like a release is not a release.
  wd="$scratch/tag-branch"
  rm -rf "$wd"
  new_app "$wd"
  if run_job "$workflow" "$job" "$wd" branch v1.2.3 ${with[@]+"${with[@]}"}; then
    fail "$workflow published from a branch"
  fi
  nothing_pushed "$workflow from a branch"
  refused_with "$workflow from a branch" "FAILED at $tag_step"
  echo "ok   $workflow publishes only a complete semantic-version tag, without build metadata"
done

# ---- 4. the two tag checks stay in lockstep -----------------------------------------------------

# The tag table above only samples the grammar, so also require both workflows to run the same
# check: every command line of their tag steps must match once each names itself the same way;
# only comment lines may differ.
tag_logic() { # <workflow> — the tag step's command lines, with the workflow's own name normalized
  local script line blank_or_comment='^[[:space:]]*(#.*)?$'
  script="$(STEP="$tag_step" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$1")"
  [[ -n "$script" ]] || fail "$1 has no '$tag_step' step"
  while IFS= read -r line; do
    if ! [[ "$line" =~ $blank_or_comment ]]; then
      line="${line//publish-manifests/<workflow>}"
      printf '%s\n' "${line//publish-app/<workflow>}"
    fi
  done <<<"$script"
}
app_logic="$(tag_logic "$app")"
manifests_logic="$(tag_logic "$manifests")"
[[ -n "$app_logic" && "$app_logic" == "$manifests_logic" ]] ||
  fail "the tag checks in $app and $manifests have drifted apart:
--- $app
$app_logic
--- $manifests
$manifests_logic"
echo "ok   both publish workflows run the same tag check"
