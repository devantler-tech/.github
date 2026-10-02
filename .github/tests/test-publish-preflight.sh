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
# setup no-ops. Stub `flux`, `cosign` and `docker` binaries record every registry call, and a failing
# step stops the job as it does on a runner. Anything the simulation does not model — an unknown
# action, expression, step condition, shell or output form, or a step or job key such as
# `continue-on-error` that would let a runner carry on past a failure — fails this test rather than
# being ignored.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

bash_bin="$(command -v bash)"
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
printf '%s\n' "$STUB_ARTIFACT_DIGEST"
EOF
chmod +x "$scratch/bin/flux" "$scratch/bin/cosign" "$scratch/bin/docker"

# ---- the simulated job ------------------------------------------------------------------------

# Per-run state, reset by run_job.
sim_workflow=""
sim_job=""
sim_step=""
sim_ref_type=""
sim_ref_name=""
sim_inputs="$scratch/inputs"   # name=value, the caller's `with:`
sim_outputs="$scratch/outputs" # <step-id>.<name>=value, from GITHUB_OUTPUT
calls="$scratch/calls"         # every registry call, in order
log="$scratch/log"             # the output of every step that ran

step() { # <yq expression> — evaluated on the current step of the simulated job
  JOB="$sim_job" I="$sim_step" yq -r ".jobs[strenv(JOB)].steps[env(I)] | $1" "$sim_workflow"
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
    github.server_url) printf '%s' "https://github.com" ;;
    github.repository) printf '%s' "devantler-tech/app" ;;
    github.actor) printf '%s' "bot" ;;
    secrets.GITHUB_TOKEN) printf '%s' "stub-not-a-secret" ;;
    env.*) lookup_line "$scratch/job-env" "${1#env.}" ;;
    inputs.*)
      input="${1#inputs.}"
      [[ "$(INPUT="$input" yq -r '.on.workflow_call.inputs | has(strenv(INPUT))' "$sim_workflow")" == true ]] ||
        return 1
      # Passed by the caller (even as an empty string) wins; otherwise the declared default applies.
      # (Not `.default // ""`: yq's alternative operator would turn a `false` default into "".)
      lookup_line "$sim_inputs" "$input" ||
        INPUT="$input" yq -r '.on.workflow_call.inputs[strenv(INPUT)] | select(has("default")) | .default' \
          "$sim_workflow"
      ;;
    steps.*.outputs.*)
      id="${1#steps.}"
      id="${id%%.outputs.*}"
      # An output the step never set is the empty string on a runner.
      lookup_line "$sim_outputs" "${id}.${1##*.outputs.}" || true
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

# run_job <workflow> <job> <workdir> <ref-type> <ref-name> [input=value ...]
# Runs the job's steps in order in <workdir>. Returns 0 when every step passed, 1 when a step
# failed (the job stops there). Exits the test on anything the simulation does not model.
run_job() {
  sim_workflow="$1"
  local job="$2" workdir="$3" count i name if_expr if_value uses action run_file push id
  sim_ref_type="$4"
  sim_ref_name="$5"
  shift 5
  : >"$sim_inputs"
  : >"$sim_outputs"
  : >"$calls"
  : >"$log"
  local pair line unmodelled
  for pair in "$@"; do printf '%s\n' "$pair" >>"$sim_inputs"; done

  # Anything that changes how a failing step or the job behaves on a runner — continue-on-error, a
  # default shell or working directory, a matrix, a job condition other than the dry-run gate the
  # simulation honours — is refused rather than ignored, so the simulation cannot pass on a job that
  # a runner would carry past a failure.
  unmodelled="$(yq -r '.defaults // {} | keys | join(" ")' "$sim_workflow")"
  [[ -z "$unmodelled" ]] || fail "$sim_workflow sets workflow defaults ($unmodelled); model them"
  unmodelled="$(JOB="$job" yq -r '.jobs[strenv(JOB)] | keys
    | map(select(. != "name" and . != "if" and . != "runs-on" and . != "permissions"
      and . != "env" and . != "steps")) | join(" ")' "$sim_workflow")"
  [[ -z "$unmodelled" ]] || fail "$sim_workflow job $job sets $unmodelled, which this test does not model"
  # shellcheck disable=SC2016 # GitHub expression compared literally.
  [[ "$(JOB="$job" yq -r '.jobs[strenv(JOB)].if // ""' "$sim_workflow")" == '${{ !inputs.dry-run }}' ]] ||
    fail "$sim_workflow job $job is no longer gated exactly on the dry-run input; model its condition"
  [[ "$(lookup_expr inputs.dry-run)" == false ]] || fail "the simulated job must run with dry-run off"

  # Job-level env, resolved once, reaches every run step.
  : >"$scratch/job-env"
  local job_env=() key value shell_flags
  while IFS= read -r line; do
    key="${line%%=*}"
    value="$(resolve "${line#*=}")" || fail "could not resolve $job job env $key"
    printf '%s=%s\n' "$key" "$value" >>"$scratch/job-env"
    job_env+=("$key=$value")
  done < <(JOB="$job" yq -r '.jobs[strenv(JOB)].env // {} | to_entries[] | .key + "=" + .value' \
    "$sim_workflow")

  count="$(JOB="$job" yq -r '.jobs[strenv(JOB)].steps | length' "$sim_workflow")"
  [[ "$count" -gt 0 ]] || fail "$sim_workflow job $job has no steps"

  sim_job="$job"
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
          printf 'setup %s\n' "$action" >>"$log"
          ;;
        docker/build-push-action)
          push="$(step '.with.push // false')"
          [[ "$push" == "true" ]] || fail "$sim_workflow '$name' builds without pushing; model it"
          printf 'image push %s\n' "$name" >>"$calls"
          [[ -z "$id" ]] || printf '%s.digest=%s\n' "$id" "$image_digest" >>"$sim_outputs"
          ;;
        *) fail "$sim_workflow step '$name' uses $action, which this test does not model; classify it" ;;
      esac
      continue
    fi

    run_file="$scratch/step-$i.sh"
    step '.run // ""' >"$run_file"
    [[ -s "$run_file" ]] || fail "$sim_workflow step '$name' has neither uses nor run"

    # The runner's own invocations: an unspecified shell is `bash -e {0}`, an explicit `bash` adds
    # pipefail. Any other shell is not modelled.
    case "$(step '.shell // ""')" in
      "") shell_flags=(-e) ;;
      bash) shell_flags=(-e -o pipefail) ;;
      *) fail "$sim_workflow step '$name' uses a shell this test does not model" ;;
    esac

    local step_env=()
    while IFS= read -r line; do
      key="${line%%=*}"
      value="$(resolve "${line#*=}")" || fail "could not resolve env $key on '$name'"
      step_env+=("$key=$value")
    done < <(step '.env // {} | to_entries[] | .key + "=" + .value')

    : >"$scratch/github-output"
    printf '== %s\n' "$name" >>"$log"
    if ! (cd "$workdir" && env -i PATH="$scratch/bin:$PATH" HOME="$HOME" TMPDIR="$scratch" \
      CALLS="$calls" STUB_ARTIFACT_DIGEST="$artifact_digest" GITHUB_OUTPUT="$scratch/github-output" \
      ${job_env[@]+"${job_env[@]}"} ${step_env[@]+"${step_env[@]}"} \
      "$bash_bin" --noprofile --norc "${shell_flags[@]}" "$run_file") >>"$log" 2>&1; then
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

# ---- 1. publish-app: a good release pushes, and pins the digest after the build -----------------

wd="$scratch/app-good"
new_app "$wd"
run_job "$app" publish "$wd" tag v1.2.3 app-name=app ||
  fail "publish-app failed a good release: $(cat "$log")"
grep -qxF "image push 🐳 Build & push image" "$calls" ||
  fail "publish-app never pushed the image; calls: $(cat "$calls")"
grep -qF "flux push artifact oci://ghcr.io/devantler-tech/app/manifests:1.2.3 " "$calls" ||
  fail "publish-app did not push the manifests artifact as 1.2.3; calls: $(cat "$calls")"
pinned="$(yq '.spec.template.spec.containers[] | select(.name == "app") | .image' \
  "$wd/deploy/deployment.yaml")"
[[ "$pinned" == "ghcr.io/devantler-tech/app@$image_digest" ]] ||
  fail "publish-app did not inject the built digest into the manifest; got: $pinned"
first_write="$(head -n 1 "$calls")"
[[ "$first_write" == "image push 🐳 Build & push image" ]] ||
  fail "publish-app's first registry write is not the image push: $first_write"
echo "ok   publish-app publishes a good release and injects the digest after the build"

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
)
long_pre="$(printf 'a%.0s' $(seq 1 130))"
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
    grep -qF "flux push artifact oci://ghcr.io/devantler-tech/app/manifests:${want} " "$calls" ||
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
# check: their tag steps may differ only in comments and in the wording of the error they print.
tag_logic() { # <workflow> — the tag step's commands, without comments or error wording
  local script line blank_or_comment='^[[:space:]]*(#.*)?$'
  script="$(STEP="$tag_step" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$1")"
  [[ -n "$script" ]] || fail "$1 has no '$tag_step' step"
  while IFS= read -r line; do
    [[ "$line" =~ $blank_or_comment || "$line" == *"::error::"* ]] || printf '%s\n' "$line"
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
