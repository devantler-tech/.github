#!/usr/bin/env bash
# Pins #925: actions/publish-app publishes a release signed AS THE CALLING WORKFLOW, and only from
# a complete v<semver> tag whose commit is on the default branch.
#
#   - Every refusal of the release tag, the signer identity, the checkout (including a persisted
#     credential), the default-branch ancestry (including when it cannot be determined), the
#     inputs, deploy-path (links, special files, anything that differs from the tagged commit) and
#     app-manifest happens before ANY registry contact: no login, no read, no write.
#   - An occupied version is refused before the first registry write.
#   - Both digests are signed and then verified against https://github.com/<GITHUB_WORKFLOW_REF>
#     before the version (and, for stable releases, latest) is exposed; any verification,
#     copy or late-occupation failure exposes nothing.
#   - The token never appears in any program's arguments: every program a step runs is wrapped to
#     record its argv, and no recorded argv may contain the token or its encoded header.
#
# The composite runs here step by step exactly as action.yaml declares it: each `run:` step with
# its own resolved `env:`, in a clean environment, under bash -eo pipefail; each `uses:` step must
# be a SHA-pinned action this simulation models (the image build is recorded as a registry write).
# Stub flux, cosign, docker and curl record every registry and API call; the default-branch fetch
# runs real git against a local server repository. Any expression, condition, step key or action
# the simulation does not model fails the test instead of being ignored.
#
# Mutation controls at the end remove each guard from a copy of the action and require the matching
# case to stop holding, so a guard that silently stops biting fails this test.

# shellcheck disable=SC2016 # `${{ }}`, `$J` and friends are GitHub and jq syntax, not shell.
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
action_dir="$root/actions/publish-app"
[[ -f "$action_dir/action.yaml" ]] || fail 'run from the repository root'
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

repo=devantler-tech/app
token=stub-not-a-secret
token_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
image_digest="sha256:$(printf 'b%.0s' $(seq 1 64))"
artifact_digest="sha256:$(printf 'a%.0s' $(seq 1 64))"
other_digest="sha256:$(printf 'c%.0s' $(seq 1 64))"
public_digest="$(printf 'd%.0s' $(seq 1 64))"

# Fixture repositories never read the developer's Git configuration (signing, URL rewrites).
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

# ---- stubs and the tools a step may use ------------------------------------------------------

mkdir -p "$scratch/bin" "$scratch/tools" "$scratch/home" "$scratch/fixture"
cat >"$scratch/bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s\n' "$*" >>"$ARGV_LOG"
printf 'flux %s\n' "$*" >>"$CALLS"
if [[ "$1 $2" == "push artifact" ]]; then
  for arg in "$@"; do
    [[ "$arg" == --path=* ]] || continue
    # Record exactly what was packaged: every file of the pushed directory with its content.
    (cd "${arg#--path=}" && find . -type f | sort | while IFS= read -r f; do printf '== %s\n' "$f"; cat "$f"; done) >"$STATE/pushed-tree"
  done
  if [[ "$FAULT" == no-artifact-digest ]]; then printf '{}\n'; else printf '{"digest":"%s"}\n' "$STUB_ARTIFACT_DIGEST"; fi
fi
EOF
cat >"$scratch/bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cosign %s\n' "$*" >>"$ARGV_LOG"
case "$1" in
  sign) printf 'cosign %s\n' "$*" >>"$CALLS" ;;
  verify)
    # The prebuilt verifier reading the original main-CI signature (not a publication check).
    if [[ "$*" == *'--certificate-identity https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main '* ]]; then
      printf 'read original-signature\n' >>"$CALLS"
      cat "$FIXTURE/signature.json"
      exit 0
    fi
    printf 'cosign %s\n' "$*" >>"$CALLS"
    ref="${*: -1}"
    if [[ "$FAULT" == verify-image && "$ref" != */manifests@* ]] ||
      [[ "$FAULT" == verify-artifact && "$ref" == */manifests@* ]]; then
      echo 'stub: no signature matches the identity' >&2
      exit 1
    fi
    : >"$STATE/verified"
    ;;
  verify-attestation)
    printf 'read original-provenance\n' >>"$CALLS"
    jq -nc --arg payload "$(base64 <"$FIXTURE/statement.json" | tr -d '\n')" '{payload:$payload}'
    ;;
  *) echo "unmodelled cosign $1" >&2; exit 1 ;;
esac
EOF
cat >"$scratch/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$ARGV_LOG"
[[ "$1 $2 $3" == "buildx imagetools create" ]] || { echo "unmodelled docker $*" >&2; exit 1; }
printf 'docker %s\n' "$*" >>"$CALLS"
for arg in "$@"; do
  if [[ "$arg" == --metadata-file=* ]]; then
    copied="$STUB_IMAGE_DIGEST"
    [[ "$FAULT" != copy-mismatch ]] || copied="$STUB_OTHER_DIGEST"
    printf '{"containerimage.descriptor":{"digest":"%s"}}\n' "$copied" >"${arg#*=}"
  fi
done
EOF
cat >"$scratch/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$ARGV_LOG"
url="${*: -1}"
output='' headers='' config='' user='' status=false
[[ "${1:-}" == -q ]] || { echo 'curl must ignore ambient .curlrc files' >&2; exit 90; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    # Accepted so that the argv record, not this stub, is what catches a credential argument.
    --user) user="$2"; shift 2 ;;
    --write-out) status=true; shift 2 ;;
    --header | -H | --data-urlencode | --proto | --connect-timeout | --max-time | --max-filesize) shift 2 ;;
    -q | --fail | --silent | --show-error | --tlsv1.2 | --get) shift ;;
    https://*) shift ;;
    *) echo "unmodelled curl argument $1" >&2; exit 91 ;;
  esac
done
case "$url" in
  https://api.github.com/repos/*/actions/runs/*)
    printf 'read %s\n' "$url" >>"$CALLS"
    [[ -z "$headers" ]] || printf 'HTTP/2 200\r\n\r\n' >"$headers"
    cat "$FIXTURE/run.json" >"$output"
    if "$status"; then printf 200; fi
    ;;
  https://ghcr.io/token)
    printf 'read %s\n' "$url" >>"$CALLS"
    # The registry login comes from a private config file (or, if a mutation puts it back, argv).
    credential="$user"
    if [[ -n "$config" ]]; then
      [[ -n "$(find "$config" -type f -perm 0600)" ]] || { echo 'login config is not private' >&2; exit 92; }
      credential="$(sed -n 's/^user = "\(.*\)"$/\1/p' "$config")"
    fi
    [[ "$credential" == "bot:$STUB_TOKEN" ]] || { echo 'wrong registry login' >&2; exit 93; }
    printf '{"token":"synthetic-bearer"}' >"$output"
    printf 200
    ;;
  https://ghcr.io/v2/*/manifests/*)
    printf 'read %s\n' "$url" >>"$CALLS"
    [[ -n "$config" ]] && grep -qx 'header = "Authorization: Bearer synthetic-bearer"' "$config" ||
      { echo 'missing bearer config' >&2; exit 94; }
    existing=false
    case "$FAULT" in
      registry-existing) existing=true ;;
      registry-image-only) [[ "$url" == */manifests/manifests/* ]] || existing=true ;;
      registry-manifests-only) [[ "$url" != */manifests/manifests/* ]] || existing=true ;;
      # The version appears in the registry after the image build, or after verification.
      registry-raced-after-build) [[ ! -e "$STATE/built" ]] || existing=true ;;
      registry-raced) [[ ! -e "$STATE/verified" ]] || existing=true ;;
    esac
    if "$existing"; then
      printf '{}' >"$output"
      printf 200
    else
      printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"
      printf 404
    fi
    ;;
  *) echo "unmodelled curl $url" >&2; exit 1 ;;
esac
EOF
cat >"$scratch/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$ARGV_LOG"
if [[ "$FAULT" == merge-base-error && "${1:-}" == merge-base ]]; then
  echo 'stub: git merge-base could not walk the history' >&2
  exit 128
fi
if [[ "${1:-}" == fetch ]]; then
  # The Authorization headers this fetch sends, as git resolves the list: an empty value resets it.
  { "$REAL_GIT" config --get-all "http.$GITHUB_SERVER_URL/.extraheader" || true; } |
    awk 'length($0) == 0 { n = 0; next } { h[++n] = $0 } END { for (i = 1; i <= n; i++) print h[i] }' >"$STATE/fetch-headers"
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$scratch/bin/"*
bash_path="$(command -v bash)"
real_git="$(command -v git)"
# Every other program a step may run is a thin wrapper that records its argv first. A step that
# reaches for anything else (oras, crane, gh, ...) fails instead of acting unseen.
for tool in awk base64 basename bash cat cmp cp cut date dirname find grep head jq mkdir mktemp mv rm sed sleep sort tail tr wc yq; do
  tool_path="$(command -v "$tool")" || fail "this test needs $tool on PATH"
  printf '#!%s\nprintf "%%s %%s\\n" %q "$*" >>"$ARGV_LOG"\nexec %q "$@"\n' "$bash_path" "$tool" "$tool_path" >"$scratch/tools/$tool"
  chmod +x "$scratch/tools/$tool"
done

# ---- the release repository and its default branch -------------------------------------------

deployment() { # <container name> <second container name> — a Deployment manifest
  printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: app' 'spec:' '  template:' \
    '    spec:' '      containers:' "        - name: $1" '          image: ghcr.io/devantler-tech/app:placeholder' \
    "        - name: $2" '          image: ghcr.io/devantler-tech/sidecar:1.0.0'
}
src="$scratch/src"
git init --quiet --initial-branch=main "$src"
mkdir -p "$src/deploy" "$src/flat-beside-base/base" "$src/split/base" "$src/nested/overlays/base" "$src/renamed" \
  "$src/k8s/base" "$src/ambiguous" "$src/missing-app" "$src/unparsable" "$src/linked"
deployment app sidecar >"$src/deploy/deployment.yaml"
cat >"$src/deploy/webapp.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: unrelated
data:
  literal: keep me
---
apiVersion: kro.run/v1alpha1
kind: WebApp
metadata:
  name: app
  namespace: app
spec:
  name: app
  image: ghcr.io/devantler-tech/app:old
  host: example.invalid
EOF
printf 'resources: [deployment.yaml]\n' >"$src/deploy/kustomization.yaml"
# Committed layouts: each directory is a deploy-path some case publishes from the tagged commit.
for layout in flat-beside-base flat-beside-base/base split/base nested/overlays/base k8s/base linked; do
  deployment app sidecar >"$src/$layout/deployment.yaml"
done
deployment app sidecar >"$src/renamed/app.yaml"
printf 'resources: [base]\n' | tee "$src/split/kustomization.yaml" "$src/k8s/kustomization.yaml" >/dev/null
deployment app app >"$src/ambiguous/deployment.yaml"
deployment web sidecar >"$src/missing-app/deployment.yaml"
printf 'spec: [\n' >"$src/unparsable/deployment.yaml"
ln -s ../deploy/kustomization.yaml "$src/linked/kustomization.yaml"
printf '*.local\n' >"$src/.gitignore"
git -C "$src" add -A
git -C "$src" commit --quiet -m initial
printf 'second\n' >"$src/README.md"
git -C "$src" add README.md
git -C "$src" commit --quiet -m 'release commit'
released="$(git -C "$src" rev-parse HEAD)"
git -C "$src" switch --quiet -c feature
printf 'unreviewed\n' >"$src/FEATURE.md"
git -C "$src" add FEATURE.md
git -C "$src" commit --quiet -m 'not on main'
feature="$(git -C "$src" rev-parse HEAD)"
git -C "$src" switch --quiet main
printf 'later\n' >>"$src/README.md"
git -C "$src" commit --quiet -am 'main moves on'
tip="$(git -C "$src" rev-parse HEAD)"

server="$scratch/server"
mkdir -p "$server/devantler-tech" "$server/Devantler-Tech" "$server/empty/devantler-tech" "$server/blob/devantler-tech"
git clone --quiet --bare "$src" "$server/devantler-tech/app.git"
git -C "$server/devantler-tech/app.git" symbolic-ref HEAD refs/heads/main
git -C "$server/devantler-tech/app.git" config uploadpack.allowAnySHA1InWant true
# Other spellings of the same repository (a case-insensitive filesystem already resolves the first).
[[ -e "$server/Devantler-Tech/App.git" ]] || ln -s ../devantler-tech/app.git "$server/Devantler-Tech/App.git"
ln -s app.git "$server/devantler-tech/.github.git"
# A repository without a default branch, and one whose HEAD names a blob instead of a commit.
git init --quiet --bare "$server/empty/devantler-tech/app.git"
git clone --quiet --bare "$src" "$server/blob/devantler-tech/app.git"
blob="$(printf 'not a commit\n' | git -C "$server/blob/devantler-tech/app.git" hash-object -w --stdin)"
git -C "$server/blob/devantler-tech/app.git" update-ref refs/tags/not-a-commit "$blob"
git -C "$server/blob/devantler-tech/app.git" symbolic-ref HEAD refs/tags/not-a-commit

# One shallow checkout per commit, as actions/checkout leaves it, copied fresh for every case.
for commit in "$released" "$feature" "$tip"; do
  git init --quiet "$scratch/template-$commit"
  git -C "$scratch/template-$commit" fetch --quiet --depth=1 --no-tags "file://$server/devantler-tech/app.git" "$commit"
  git -C "$scratch/template-$commit" checkout --quiet --detach FETCH_HEAD
done

# Prebuilt-webapp evidence for the released commit (see test-prebuilt-webapp.sh for its refusals).
jq -n --arg sha "$released" '{
  id:321,run_attempt:1,status:"completed",conclusion:"success",event:"push",
  head_sha:$sha,head_branch:"main",path:".github/workflows/ci.yaml",
  repository:{full_name:"devantler-tech/app",private:false},head_repository:{full_name:"devantler-tech/app",private:false}
}' >"$scratch/fixture/run.json"
jq -n --arg digest "$image_digest" --arg sha "$released" --arg public "$public_digest" '[{
  critical:{identity:{"docker-reference":("ghcr.io/devantler-tech/app@"+$digest)},image:{"docker-manifest-digest":$digest}},
  optional:{}
}]' >"$scratch/fixture/signature.json"
jq -n --arg sha "$released" --arg digest "${image_digest#sha256:}" --arg public "$public_digest" '{
  predicateType:"https://slsa.dev/provenance/v0.2",
  subject:[{name:"ghcr.io/devantler-tech/app",digest:{sha256:$digest}}],
  predicate:{builder:{id:"https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main"},
    buildType:"https://devantler.tech/build-types/combined-runtime-container/v1",
    invocation:{configSource:{uri:"git+https://github.com/devantler-tech/app",digest:{sha1:$sha},entryPoint:".github/workflows/ci.yaml"},
      parameters:{ciRunId:"321",ciRunAttempt:"1",publicDigest:$public,publicProfile:"production-template"}},
    metadata:{buildInvocationId:"https://github.com/devantler-tech/app/actions/runs/321"},
    materials:[{uri:"git+https://github.com/devantler-tech/app",digest:{sha1:$sha}}]}
}' >"$scratch/fixture/statement.json"

# ---- the composite simulation ----------------------------------------------------------------

calls="$scratch/calls"     # every registry/API contact, in order
log="$scratch/log"         # the output of every step that ran
state="$scratch/state"     # stub markers (built, verified)
inputs="$scratch/inputs"   # one file per input the caller passes, holding its raw value
outputs="$scratch/outputs" # <step-id>/<name>, from GITHUB_OUTPUT
argv_log="$scratch/argv"     # every program a step ran, with its arguments
argv_all="$scratch/argv-all" # every argv of every unmutated case

# setup_case <commit> — a fresh workspace at <commit> and the default healthy caller.
setup_case() {
  ws="$scratch/ws"
  rm -rf "$ws" "$scratch/outer" "$inputs" "$outputs" "$state" "$scratch/runner-temp" "$scratch/action-outputs"
  mkdir -p "$inputs" "$outputs" "$state" "$scratch/runner-temp" "$scratch/action-outputs"
  : >"$calls"
  : >"$log"
  : >"$argv_log"
  cp -R "$scratch/template-$1" "$ws"
  sim_sha="$1"
  sim_ref=refs/tags/v1.2.3
  sim_workflow_ref=''
  sim_repository="$repo"
  sim_server="file://$server"
  sim_git_global=/dev/null
  FAULT=none
  set_input app-name app
}
set_input() { printf '%s' "$2" >"$inputs/$1"; }
unset_input() { rm -f "$inputs/$1"; }

# input_value <name> — the caller's value (even empty) or the declared default.
input_value() {
  [[ "$(jq --arg n "$1" '.inputs | has($n)' "$sim_json")" == true ]] || {
    echo "undeclared input $1" >&2
    return 1
  }
  if [[ -f "$inputs/$1" ]]; then
    cat "$inputs/$1"
    return 0
  fi
  local default
  default="$(jq -r --arg n "$1" '.inputs[$n].default // ""' "$sim_json")"
  if [[ "$default" == '${{ github.token }}' ]]; then printf '%s' "$token"; else printf '%s' "$default"; fi
}

resolve_expr() { # <expression> — what GitHub substitutes for ${{ <expression> }}
  local id name
  case "$1" in
    github.actor) printf bot ;;
    inputs.*) input_value "${1#inputs.}" ;;
    steps.*.outputs.*)
      id="${1#steps.}"
      id="${id%%.outputs.*}"
      name="${1##*.outputs.}"
      if [[ -f "$outputs/$id/$name" ]]; then cat "$outputs/$id/$name"; fi
      ;;
    *)
      echo "unmodelled expression: $1" >&2
      return 1
      ;;
  esac
}

substitute() { # <string> — every ${{ expression }} resolved
  local rest="$1" out='' expr value
  while [[ "$rest" == *'${{'* ]]; do
    out+="${rest%%'${{'*}"
    rest="${rest#*'${{'}"
    [[ "$rest" == *'}}'* ]] || return 1
    expr="${rest%%'}}'*}"
    rest="${rest#*'}}'}"
    expr="${expr#"${expr%%[![:space:]]*}"}"
    expr="${expr%"${expr##*[![:space:]]}"}"
    value="$(resolve_expr "$expr" && printf x)" || return 1
    out+="${value%x}"
  done
  printf '%s' "$out$rest"
}

step_json() { jq -c --argjson i "$1" '.runs.steps[$i]' "$sim_json"; }

# run_action <action-dir> — runs the composite in $ws; 0 when every step succeeded. The argv of
# every unmutated run is kept for the suite-wide no-credential check.
run_action() {
  local status=0
  run_steps "$@" || status=$?
  [[ -n "${mutating:-}" ]] || cat "$argv_log" >>"$argv_all"
  return "$status"
}
run_steps() {
  local dir="$1" count i step name id cond uses key value status out_file line
  local -a env_args step_env
  sim_json="$scratch/action.json"
  yq -o=json '.' "$dir/action.yaml" >"$sim_json"
  [[ "$(jq -r '.runs.using' "$sim_json")" == composite ]] || { echo 'not a composite action' >>"$log"; return 1; }
  [[ -n "$sim_workflow_ref" ]] || sim_workflow_ref="$sim_repository/.github/workflows/release.yaml@$sim_ref"
  env_args=(
    "PATH=$scratch/bin:$scratch/tools" "HOME=$scratch/home"
    GIT_CONFIG_NOSYSTEM=1 "GIT_CONFIG_GLOBAL=$sim_git_global" RETRY_BASE_DELAY=0
    "ARGV_LOG=$argv_log" "REAL_GIT=$real_git" "STUB_TOKEN=$token"
    "GITHUB_REF=$sim_ref" "GITHUB_SHA=$sim_sha" "GITHUB_REPOSITORY=$sim_repository"
    "GITHUB_WORKFLOW_REF=$sim_workflow_ref" "GITHUB_SERVER_URL=$sim_server"
    GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=2 GITHUB_ACTOR=bot
    "GITHUB_ACTION_PATH=$dir" "RUNNER_TEMP=$scratch/runner-temp"
    "CALLS=$calls" "STATE=$state" "FAULT=$FAULT" "FIXTURE=$scratch/fixture"
    "STUB_ARTIFACT_DIGEST=$artifact_digest" "STUB_IMAGE_DIGEST=$image_digest" "STUB_OTHER_DIGEST=$other_digest"
  )
  count="$(jq '.runs.steps | length' "$sim_json")"
  for ((i = 0; i < count; i++)); do
    step="$(step_json "$i")"
    name="$(jq -r '.name' <<<"$step")"
    id="$(jq -r '.id // ""' <<<"$step")"
    if ! jq -e 'keys - ["name","id","if","shell","env","run","uses","with"] == []' <<<"$step" >/dev/null; then
      echo "unmodelled step key in $name" >>"$log"
      return 1
    fi
    cond="$(jq -r '.if // ""' <<<"$step")"
    if [[ -n "$cond" ]]; then
      if [[ "$cond" =~ ^\$\{\{\ inputs\.mode\ ==\ \'([a-z-]+)\'\ \}\}$ ]]; then
        [[ "$(input_value mode)" == "${BASH_REMATCH[1]}" ]] || continue
      else
        echo "unmodelled condition in $name: $cond" >>"$log"
        return 1
      fi
    fi
    if [[ "$(jq -r 'has("run")' <<<"$step")" == true ]]; then
      [[ "$(jq -r '.shell // ""' <<<"$step")" == bash ]] || { echo "unmodelled shell in $name" >>"$log"; return 1; }
      step_env=()
      while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        value="$(substitute "$(jq -r --arg k "$key" '.env[$k]' <<<"$step")" && printf x)" || {
          echo "FAILED to resolve $key in $name" >>"$log"
          return 1
        }
        step_env+=("$key=${value%x}")
      done < <(jq -r '.env // {} | keys[]' <<<"$step")
      out_file="$scratch/runner-temp/output-$i"
      : >"$out_file"
      status=0
      (cd "$ws" && /usr/bin/env -i "${env_args[@]}" "${step_env[@]}" "GITHUB_OUTPUT=$out_file" \
        "$bash_path" --noprofile --norc -eo pipefail -c "$(jq -r '.run' <<<"$step")") >>"$log" 2>&1 || status=$?
      if [[ "$status" != 0 ]]; then
        echo "FAILED at $name" >>"$log"
        return 1
      fi
      if [[ -n "$id" ]]; then
        mkdir -p "$outputs/$id"
        while IFS= read -r line; do
          [[ "$line" == *=* && "$line" != *'<<'* ]] || { echo "unmodelled output line in $name" >>"$log"; return 1; }
          printf '%s' "${line#*=}" >"$outputs/$id/${line%%=*}"
        done <"$out_file"
      fi
      continue
    fi
    uses="$(jq -r '.uses' <<<"$step")"
    [[ "$uses" =~ ^([a-z0-9/._-]+)@[0-9a-f]{40}$ ]] || { echo "unpinned action in $name" >>"$log"; return 1; }
    case "${BASH_REMATCH[1]}" in
      fluxcd/flux2/action | sigstore/cosign-installer) ;;
      docker/login-action)
        [[ "$(substitute "$(jq -r '.with.password' <<<"$step")")" == "$token" &&
          "$(substitute "$(jq -r '.with.username' <<<"$step")")" == bot ]] || { echo 'login lost its credential' >>"$log"; return 1; }
        printf 'login %s\n' "$(jq -r '.with.registry' <<<"$step")" >>"$calls"
        ;;
      docker/metadata-action)
        mkdir -p "$outputs/$id"
        printf 'org.opencontainers.image.source=%s' "$(substitute "$(jq -r '.with.images' <<<"$step")")" >"$outputs/$id/labels"
        ;;
      docker/build-push-action)
        [[ "$(jq -r '.with.push' <<<"$step")" == true && "$(jq -r '.with.context' <<<"$step")" == . ]] ||
          { echo 'unmodelled build' >>"$log"; return 1; }
        printf 'image push %s labels=%s\n' "$(substitute "$(jq -r '.with.tags' <<<"$step")")" \
          "$(substitute "$(jq -r '.with.labels' <<<"$step")")" >>"$calls"
        : >"$state/built"
        mkdir -p "$outputs/$id"
        printf '%s' "$image_digest" >"$outputs/$id/digest"
        ;;
      *)
        echo "unmodelled action ${BASH_REMATCH[1]}" >>"$log"
        return 1
        ;;
    esac
  done
  while IFS= read -r key; do
    substitute "$(jq -r --arg k "$key" '.outputs[$k].value' "$sim_json")" >"$scratch/action-outputs/$key"
  done < <(jq -r '.outputs // {} | keys[]' "$sim_json")
}

# ---- what a case must show --------------------------------------------------------------------

writes() { grep -E '^(image push|flux push|flux tag|cosign sign|docker buildx imagetools create)' "$calls" || true; }
exposed() { grep -E '^flux tag |^docker buildx imagetools create' "$calls" | grep -v ':verified-' || true; }
snapshot() { (cd "$ws" && find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r f; do printf '== %s\n' "$f"; cat "$f"; done) >"$scratch/snapshot-$1"; }
action_output() { cat "$scratch/action-outputs/$1"; }

# admission_refusal <action-dir> <reason> — refused by admission, before any registry contact,
# for <reason>, with the workspace untouched.
admission_refusal() {
  snapshot before
  if run_action "$1"; then return 1; fi
  snapshot after
  [[ ! -s "$calls" ]] || return 1
  grep -qF 'FAILED at 🔒 Admit the release tag, inputs and manifests' "$log" || return 1
  grep -qF -- "$2" "$log" || return 1
  cmp -s "$scratch/snapshot-before" "$scratch/snapshot-after"
}

# no_credential_in_argv — no program received the token, or the header that encodes it, as an
# argument; flux in particular gets no --creds and reads the docker login instead.
no_credential_in_argv() {
  [[ -s "$argv_log" ]] || return 1
  ! grep -qF -- "$token" "$argv_log" || return 1
  ! grep -qF -- "${token_header#AUTHORIZATION: basic }" "$argv_log" || return 1
  ! grep -qE -- "^flux .*--creds" "$argv_log"
}

# published <action-dir> <version> [latest] — a complete publication of <version>.
published() {
  run_action "$1" || return 1
  no_credential_in_argv || return 1
  [[ "$(action_output version)" == "$2" ]] || return 1
  [[ "$(action_output manifests-digest)" == "$artifact_digest" ]] || return 1
  local pointers
  pointers="$(exposed)"
  grep -qE "^flux tag .* --tag $2( |$)" <<<"$pointers" || return 1
  if [[ "${3:-}" == latest ]]; then
    grep -qE '^flux tag .* --tag latest( |$)' <<<"$pointers" || return 1
  else
    ! grep -qE -- '--tag latest( |$)|:latest ' <<<"$pointers" || return 1
  fi
}

# verified_before_exposed — both signatures verified against the caller's identity at its tag,
# and nothing selectable written before the last verification.
verified_before_exposed() {
  local identity="https://github.com/$sim_workflow_ref" last_verify first_expose
  [[ "$(grep -cE "^cosign verify --certificate-identity $identity --certificate-oidc-issuer https://token.actions.githubusercontent.com " "$calls")" == "$1" ]] || return 1
  [[ "$(grep -c '^cosign verify' "$calls")" == "$1" ]] || return 1
  last_verify="$(grep -n '^cosign verify' "$calls" | tail -n 1 | cut -d: -f1)"
  first_expose="$(grep -nE '^flux tag |^docker buildx imagetools create' "$calls" | grep -v ':verified-' | head -n 1 | cut -d: -f1)"
  [[ -n "$last_verify" && -n "$first_expose" && "$last_verify" -lt "$first_expose" ]]
}

# nothing_exposed — a failure after staging leaves no version or latest pointer behind.
nothing_exposed() {
  run_action "$1" && return 1
  [[ -z "$(exposed)" ]] || return 1
  [[ -s "$calls" ]]
}

# ---- 1. the release ref and the signer identity -----------------------------------------------

case_ref() { # <action-dir> <ref> <reason>
  setup_case "$released"
  sim_ref="$2"
  admission_refusal "$1" "$3"
}
for ref in refs/heads/main refs/pull/7/merge refs/heads/v1.2.3 v1.2.3; do
  case_ref "$action_dir" "$ref" 'must run on a release tag' || fail "accepted or misjudged non-tag ref $ref: $(cat "$log")"
done
long_pre="$(printf 'a%.0s' $(seq 1 130))"
long_build="$(printf 'b%.0s' $(seq 1 251))"
for tag in v1.2.3garbage v1.2.3.4 v1.2 v1 1.2.3 V1.2.3 v01.2.3 v1.02.3 v1.2.03 v1.2.3- v1.2.3+ v1.2.3-01 \
  v1.2.3-rc..1 v1.2.3-rc.1+ v1.2.3+build..1 v1.2.3_build 'v1.2.3 ' ' v1.2.3' v1.2.3-ünicode; do
  case_ref "$action_dir" "refs/tags/$tag" 'complete semantic version' || fail "accepted or misjudged tag '$tag': $(cat "$log")"
done
for tag in v9007199254740992.0.0 v1.0.18446744073709551616 v1.2.3-rc.1000000000000000 "v1.2.3+$long_build"; do
  case_ref "$action_dir" "refs/tags/$tag" 'at most 256 characters with numbers of at most 15 digits' ||
    fail "accepted an unreadable version $tag: $(cat "$log")"
done
case_ref "$action_dir" "refs/tags/v1.2.3-$long_pre" 'longer than the 128 characters' || fail 'accepted an over-long OCI version'
echo 'ok   only a complete v<semver> tag ref is admitted, before any registry contact'

for entry in "v0.0.0|0.0.0|latest" "v10.20.30|10.20.30|latest" "v1.2.3-rc.1|1.2.3-rc.1|" \
  "v1.0.0-alpha.beta.1|1.0.0-alpha.beta.1|" "v1.0.0-x-y-z.--|1.0.0-x-y-z.--|" "v1.2.3+build.5|1.2.3|latest" \
  "v1.2.3-rc.1+build.5|1.2.3-rc.1|" "v999999999999999.0.0|999999999999999.0.0|latest"; do
  IFS='|' read -r tag version latest <<<"$entry"
  setup_case "$released"
  sim_ref="refs/tags/$tag"
  published "$action_dir" "$version" "$latest" || fail "did not publish $tag as $version: $(cat "$log")"
  grep -qF -- "-a devantler.source-ref=$tag " "$calls" || fail "$tag: the signature does not claim the tag"
done
echo 'ok   SemVer tags publish their normalized version; prereleases never move latest'

case_identity() { # <action-dir> <workflow-ref> <reason>
  setup_case "$released"
  sim_workflow_ref="$2"
  admission_refusal "$1" "$3"
}
belong='the calling workflow must belong to devantler-tech/app and run on refs/tags/v1.2.3'
for workflow_ref in \
  "devantler-tech/other/.github/workflows/release.yaml@refs/tags/v1.2.3|$belong" \
  "devantler-tech/app/.github/workflows/release.yaml@refs/heads/main|$belong" \
  "devantler-tech/app/.github/workflows/release.yaml@refs/tags/v1.2.4|$belong" \
  "devantler-tech/.github/.github/workflows/publish-app.yaml@refs/tags/v1.2.3|$belong" \
  "devantler-tech/app/.github/workflows/sub/release.yaml@refs/tags/v1.2.3|a file directly in .github/workflows" \
  "devantler-tech/app/.github/workflows/.hidden.yaml@refs/tags/v1.2.3|a file directly in .github/workflows"; do
  case_identity "$action_dir" "${workflow_ref%%|*}" "${workflow_ref#*|}" ||
    fail "accepted or misjudged signer identity ${workflow_ref%%|*}: $(cat "$log")"
done
echo "ok   the signer identity must be the caller's own workflow at the release tag"

# ---- 2. the checkout and the default branch ---------------------------------------------------

case_head_moved() {
  setup_case "$released"
  sim_sha="$tip"
  admission_refusal "$1" "the checked-out commit is not the tagged commit $tip"
}
case_head_moved "$action_dir" || fail "accepted a checkout of another commit: $(cat "$log")"
setup_case "$released"
rm -rf "$ws/.git"
admission_refusal "$action_dir" 'check out the tagged commit' || fail "accepted a workspace without a checkout: $(cat "$log")"
# A checkout below the workspace root: HEAD resolves, but the workspace is not the repository.
case_outer() {
  setup_case "$released"
  mv "$ws" "$scratch/outer"
  ws="$scratch/outer/deploy"
  admission_refusal "$1" 'at the workspace root (actions/checkout without a path)'
}
case_outer "$action_dir" || fail "accepted a workspace inside a checkout: $(cat "$log")"

# actions/checkout persists its token unless told not to, either in the local config or in a file
# the local config includes. Either way the checkout (and so the image build context) carries it.
case_persisted() { # <action-dir> <direct|included>
  setup_case "$released"
  if [[ "$2" == direct ]]; then
    git -C "$ws" config --local http.https://github.com/.extraheader 'AUTHORIZATION: basic cGVyc2lzdGVk'
  else
    printf '[http "https://github.com/"]\n\textraheader = AUTHORIZATION: basic cGVyc2lzdGVk\n' >"$scratch/persisted.gitconfig"
    git -C "$ws" config --local "includeIf.gitdir:$(cd "$ws/.git" && pwd -P).path" "$scratch/persisted.gitconfig"
  fi
  admission_refusal "$1" 'the checkout persisted a git credential; check out with persist-credentials: false'
}
for style in direct included; do
  case_persisted "$action_dir" "$style" || fail "accepted a checkout with a $style persisted credential: $(cat "$log")"
done

case_not_on_default() {
  setup_case "$feature"
  admission_refusal "$1" "points to $feature, which is not on the default branch"
}
case_not_on_default "$action_dir" || fail "accepted a tag on a commit outside the default branch: $(cat "$log")"

case_undeterminable() { # <action-dir> <server> — the default branch cannot be fetched from <server>
  setup_case "$released"
  sim_server="$2"
  admission_refusal "$1" 'could not fetch the default branch'
}
case_undeterminable "$action_dir" "file://$scratch/nowhere" || fail "accepted an unreachable default branch: $(cat "$log")"
case_undeterminable "$action_dir" "file://$server/empty" || fail "accepted a repository without a default branch: $(cat "$log")"
case_no_commit() { # the remote HEAD names a blob, so the fetch succeeds without a commit
  setup_case "$released"
  sim_server="file://$server/blob"
  admission_refusal "$1" 'no default branch commit was fetched'
}
case_no_commit "$action_dir" || fail "accepted a default branch that is not a commit: $(cat "$log")"
case_ancestry_error() { # git cannot answer the ancestry question (exit 128)
  setup_case "$released"
  FAULT=merge-base-error
  admission_refusal "$1" 'is on the default branch (git exit 128)'
}
case_ancestry_error "$action_dir" || fail "accepted an unanswered ancestry check: $(cat "$log")"

# The tag on an older default-branch commit (main moved on) and on the tip both publish, from a
# shallow checkout; the fetch carries the token only in its environment.
setup_case "$released"
published "$action_dir" 1.2.3 latest || fail "refused a tag behind the default branch tip: $(cat "$log")"
setup_case "$tip"
published "$action_dir" 1.2.3 latest || fail "refused a tag at the default branch tip: $(cat "$log")"
! grep -rqF "$token" "$ws/.git/config" || fail 'the default-branch fetch persisted the token'

# An inherited header for the same host (here from the global config) is reset, so the fetch sends
# exactly one Authorization header: the token's.
case_one_header() {
  setup_case "$released"
  printf '[http "%s/"]\n\textraheader = AUTHORIZATION: basic aW5oZXJpdGVk\n' "$sim_server" >"$scratch/global.gitconfig"
  sim_git_global="$scratch/global.gitconfig"
  published "$1" 1.2.3 latest || return 1
  [[ "$(cat "$state/fetch-headers")" == "$token_header" ]]
}
case_one_header "$action_dir" || fail "the default-branch fetch did not send exactly the token header: $(cat "$state/fetch-headers" "$log")"
echo 'ok   only the tagged, credential-free checkout of a default-branch commit is admitted; unknown ancestry refuses'

# ---- 3. inputs, deploy-path and app-manifest ---------------------------------------------------

case_inputs() { # <action-dir> <reason> <name=value>... (a name without = is removed)
  local dir="$1" reason="$2" setting
  shift 2
  setup_case "$released"
  for setting in "$@"; do
    if [[ "$setting" == *=* ]]; then set_input "${setting%%=*}" "${setting#*=}"; else unset_input "$setting"; fi
  done
  admission_refusal "$dir" "$reason"
}
dns='app-name must be a DNS label'
prebuilt_ok=(mode=prebuilt-webapp "prebuilt-image-digest=$image_digest" "prebuilt-public-digest=$public_digest"
  prebuilt-ci-run-id=321 prebuilt-ci-run-attempt=1)
case_inputs "$action_dir" 'mode must be deployment, prebuilt-webapp or manifests' mode=Deployment || fail 'accepted an unknown mode'
case_inputs "$action_dir" 'mode must be deployment, prebuilt-webapp or manifests' mode= || fail 'accepted an empty mode'
case_inputs "$action_dir" "$dns" app-name || fail 'accepted a missing app-name'
case_inputs "$action_dir" "$dns" app-name=App || fail 'accepted an invalid app-name'
case_inputs "$action_dir" "$dns" 'app-name=a$(id)' || fail 'accepted an unsafe app-name'
case_inputs "$action_dir" 'missing registry credentials' github-token= || fail 'accepted an empty github-token'
case_inputs "$action_dir" 'oci-name applies only to manifests mode' oci-name=devantler-tech/app || fail 'accepted oci-name for an app'
case_inputs "$action_dir" 'prebuilt-* inputs apply only to prebuilt-webapp mode' prebuilt-ci-run-id=321 ||
  fail 'accepted prebuilt evidence in deployment mode'
case_inputs "$action_dir" 'manifests mode takes no app-name' mode=manifests || fail 'accepted app-name in manifests mode'
case_inputs "$action_dir" 'manifests mode takes no app-name' mode=manifests app-name app-manifest=deployment.yaml ||
  fail 'accepted app-manifest in manifests mode'
case_inputs "$action_dir" 'oci-name must stay in the devantler-tech namespace' mode=manifests app-name oci-name=someone-else/config ||
  fail 'accepted an oci-name outside the caller namespace'
case_inputs "$action_dir" 'not a valid registry path' mode=manifests app-name oci-name=devantler-tech/.github ||
  fail 'accepted an invalid oci-name'
for setting in prebuilt-image-digest=latest prebuilt-public-digest=wrong prebuilt-ci-run-id=0 prebuilt-ci-run-attempt=x; do
  case_inputs "$action_dir" 'prebuilt-' "${prebuilt_ok[@]}" "$setting" || fail "accepted prebuilt input $setting"
done
setup_case "$released"
sim_repository=devantler-tech/.github
admission_refusal "$action_dir" 'not a valid registry path' || fail "accepted an image name that is not a registry path: $(cat "$log")"
echo 'ok   mode, app-name, oci-name, prebuilt evidence and credentials are checked before any registry contact'

plain_deploy='deploy-path must be a relative directory of plain names'
for deploy in /deploy ../deploy deploy/../deploy ./deploy/ . '' .hidden 'deploy/./x' $'deploy\n' $'deploy\r'; do
  case_inputs "$action_dir" 'deploy-path' "deploy-path=$deploy" || fail "accepted deploy-path '$deploy': $(cat "$log")"
  grep -qF -- "$plain_deploy" "$log" || grep -qF 'deploy-path must not contain a line break' "$log" ||
    fail "deploy-path '$deploy' refused for the wrong reason: $(grep '::error::' "$log")"
done
case_deploy_link() {
  setup_case "$released"
  mv "$ws/deploy" "$ws/outside"
  ln -s outside "$ws/deploy"
  admission_refusal "$1" 'deploy-path passes through a link'
}
case_deploy_link "$action_dir" || fail "accepted a linked deploy-path: $(cat "$log")"
case_inputs "$action_dir" 'is not a directory' deploy-path=./nowhere || fail 'accepted a missing deploy-path'

# app-manifest: the #922 cases, ported. A valid manifest sits wherever each path would lead, so
# only the input checks can refuse it.
plain_manifest='app-manifest must be a relative path of plain names inside deploy-path'
case_manifest() { # <action-dir> <mode> <app-manifest or a layout name> <reason>
  local dir="$1" mode="$2" manifest="$3" reason="$4" file=deployment.yaml
  [[ "$mode" == deployment ]] || file=webapp.yaml
  setup_case "$released"
  if [[ "$mode" != deployment ]]; then
    local setting
    for setting in "${prebuilt_ok[@]}"; do set_input "${setting%%=*}" "${setting#*=}"; done
  fi
  mkdir -p "$ws/deploy/base" "$ws/deploy/.hidden"
  cp "$ws/deploy/$file" "$ws/deploy/base/$file"
  cp "$ws/deploy/$file" "$ws/deploy/.hidden/$file"
  cp "$ws/deploy/$file" "$ws/$file"
  case "$manifest" in
    linked-dir) mv "$ws/deploy/base" "$ws/outside" && ln -s ../outside "$ws/deploy/base" ;;
    linked-file) mv "$ws/deploy/base/$file" "$ws/outside.yaml" && ln -s ../../outside.yaml "$ws/deploy/base/$file" ;;
    missing) rm "$ws/deploy/base/$file" ;;
  esac
  case "$manifest" in linked-dir | linked-file | missing) manifest="base/$file" ;; esac
  set_input app-manifest "$manifest"
  admission_refusal "$dir" "$reason"
}
for mode in deployment prebuilt-webapp; do
  file=deployment.yaml
  [[ "$mode" == deployment ]] || file=webapp.yaml
  for entry in "../$file|$plain_manifest" "/$file|$plain_manifest" "base/./$file|$plain_manifest" \
    "base/../$file|$plain_manifest" "base//$file|$plain_manifest" "base/|$plain_manifest" \
    ".hidden/$file|$plain_manifest" "base/$file"$'\n'"::error::injected|$plain_manifest" \
    "base/$file"$'\r'"|$plain_manifest" $'\n'"base/$file|$plain_manifest" \
    "linked-dir|app-manifest passes through a link" "linked-file|app-manifest passes through a link" \
    "missing|app manifest ./deploy/base/$file not found"; do
    manifest="${entry%%|*}"
    case_manifest "$action_dir" "$mode" "$manifest" "${entry#*|}" ||
      fail "$mode accepted or misjudged app-manifest '$manifest': $(grep '::error::' "$log" || cat "$log")"
    ! grep -qF 'injected' "$log" || fail 'an unchecked app-manifest reached the log'
  done
done

case_containers() { # <action-dir> <committed deploy-path> <reason>
  setup_case "$released"
  set_input deploy-path "./$2"
  admission_refusal "$1" "$3"
}
case_containers "$action_dir" ambiguous "expected exactly one container named 'app'" || fail "accepted two app containers: $(cat "$log")"
case_containers "$action_dir" missing-app "expected exactly one container named 'app'" ||
  fail "accepted a Deployment without the app container: $(cat "$log")"
case_containers "$action_dir" unparsable 'cannot read ./unparsable/deployment.yaml as a Deployment' ||
  fail "accepted an unparsable manifest: $(cat "$log")"

# Everything under deploy-path is published: a committed link, or a special file, is refused in
# every mode, as the prebuilt verifier already refuses them.
linked_reason='deploy-path must hold only regular files and directories (no links or special files)'
case_linked_contents() { # <action-dir> <mode>
  setup_case "$released"
  set_input deploy-path ./linked
  if [[ "$2" == manifests ]]; then set_input mode manifests; unset_input app-name; fi
  admission_refusal "$1" "$linked_reason"
}
for mode in deployment manifests; do
  case_linked_contents "$action_dir" "$mode" || fail "$mode accepted a link inside deploy-path: $(cat "$log")"
done
setup_case "$released"
mkfifo "$ws/deploy/pipe"
admission_refusal "$action_dir" "$linked_reason" || fail "accepted a special file inside deploy-path: $(cat "$log")"

# The signed manifests are the tagged source: a changed, removed or added file in deploy-path
# (an ignored one included) is refused; changes elsewhere in the workspace are not.
case_source() { # <action-dir> <change> <reason>
  setup_case "$released"
  case "$2" in
    modified) printf 'patched: true\n' >>"$ws/deploy/kustomization.yaml" ;;
    staged) printf 'patched: true\n' >>"$ws/deploy/kustomization.yaml" && git -C "$ws" add deploy/kustomization.yaml ;;
    removed) rm "$ws/deploy/webapp.yaml" ;;
    untracked) printf 'kind: Secret\n' >"$ws/deploy/extra.yaml" ;;
    ignored) printf 'kind: Secret\n' >"$ws/deploy/values.local" ;;
  esac
  admission_refusal "$1" "$3"
}
differs='deploy-path deploy differs from the tagged commit'
untracked='deploy-path deploy holds files that are not in the tagged commit'
for entry in "modified|$differs" "staged|$differs" "removed|$differs" "untracked|$untracked" "ignored|$untracked"; do
  case_source "$action_dir" "${entry%%|*}" "${entry#*|}" || fail "accepted a ${entry%%|*} file in deploy-path: $(cat "$log")"
done
setup_case "$released"
printf 'built\n' >>"$ws/README.md"
mkdir -p "$ws/dist"
printf 'built\n' >"$ws/dist/out.txt"
published "$action_dir" 1.2.3 latest || fail "refused build outputs outside deploy-path: $(cat "$log")"
echo 'ok   deploy-path, app-manifest and the app container are refused before any registry contact'

# ---- 4. an occupied version ---------------------------------------------------------------------

case_occupied() { # <action-dir> <fault> [mode]
  setup_case "$released"
  FAULT="$2"
  if [[ "${3:-}" == manifests ]]; then set_input mode manifests; unset_input app-name; fi
  run_action "$1" && return 1
  grep -qF 'FAILED at 🔒 Refuse an occupied release version' "$log" || return 1
  grep -qF 'already exists' "$log" || return 1
  [[ -z "$(writes)" ]]
}
for fault in registry-existing registry-image-only registry-manifests-only; do
  case_occupied "$action_dir" "$fault" || fail "did not refuse $fault before the first write: $(cat "$calls")"
done
case_occupied "$action_dir" registry-manifests-only manifests || fail 'manifests mode did not refuse an occupied version'
case_raced_after_build() {
  setup_case "$released"
  FAULT=registry-raced-after-build
  run_action "$1" && return 1
  grep -qF 'already exists' "$log" || return 1
  [[ "$(writes)" == "image push "* && "$(writes | wc -l | tr -d ' ')" == 1 ]]
}
case_raced_after_build "$action_dir" || fail "staged or signed after the version appeared: $(cat "$calls")"
echo 'ok   an occupied version is refused before the first registry write, and again before staging'

# ---- 5. healthy publication in every mode ------------------------------------------------------

case_deployment() { # <action-dir> — the complete, ordered deployment-mode publication
  local image=ghcr.io/devantler-tech/app artifact=ghcr.io/devantler-tech/app/manifests
  setup_case "$released"
  published "$1" 1.2.3 latest || return 1
  verified_before_exposed 2 || return 1
  # Exact calls, except that a trailing " *" leaves the claims (checked below) to a prefix match.
  local -a expected=(
    "login ghcr.io"
    "image push $image:staging-123-2 labels=org.opencontainers.image.source=$image"
    "flux push artifact oci://$artifact:staging-123-2 --path=./deploy --source=file://$server/$repo --revision=v1.2.3@sha1:$released --output json"
    "cosign sign --yes *"
    "cosign sign --yes *"
    "cosign verify *"
    "cosign verify *"
    "docker buildx imagetools create --prefer-index=false --tag $image:verified-123-2 --metadata-file=$scratch/runner-temp/publish-app-copy.json $image@$image_digest"
    "docker buildx imagetools create --prefer-index=false --tag $image:1.2.3 $image@$image_digest"
    "flux tag artifact oci://$artifact@$artifact_digest --tag 1.2.3"
    "docker buildx imagetools create --prefer-index=false --tag $image:latest $image@$image_digest"
    "flux tag artifact oci://$artifact@$artifact_digest --tag latest"
  )
  local actual i=0 line
  actual="$(grep -v '^read ' "$calls")"
  [[ "$(wc -l <<<"$actual" | tr -d ' ')" == "${#expected[@]}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${expected[$i]}" == *" *" ]]; then
      [[ "$line" == "${expected[$i]%\*}"* ]] || return 1
    else
      [[ "$line" == "${expected[$i]}" ]] || return 1
    fi
    i=$((i + 1))
  done <<<"$actual"
  # Three authenticated absence checks over both repositories: before the build, before staging
  # and before exposure.
  [[ "$(grep -c "^read https://ghcr.io/v2/devantler-tech/app/manifests/1.2.3$" "$calls")" == 3 ]] || return 1
  [[ "$(grep -c "^read https://ghcr.io/v2/devantler-tech/app/manifests/manifests/1.2.3$" "$calls")" == 3 ]] || return 1
  # Image and artifact are signed by digest, with the publication claims.
  local claim
  for claim in "repository=$repo" "source-sha=$released" "source-ref=v1.2.3" "version=1.2.3" "run-id=123" \
    "run-attempt=2" "workflow-ref=$repo/.github/workflows/release.yaml@refs/tags/v1.2.3" \
    "image-digest=$image_digest" "manifests-digest=$artifact_digest"; do
    [[ "$(grep -cF -- "-a devantler.$claim " "$calls")" == 4 ]] || return 1
  done
  grep -qE "^cosign sign .* $image@$image_digest$" "$calls" || return 1
  grep -qE "^cosign sign .* $artifact@$artifact_digest$" "$calls" || return 1
  # The pushed tree is the whole deploy path with only the app container pinned.
  grep -qxF '== ./kustomization.yaml' "$state/pushed-tree" || return 1
  grep -qxF '== ./webapp.yaml' "$state/pushed-tree" || return 1
  [[ "$(yq '.spec.template.spec.containers[] | select(.name == "app") | .image' "$ws/deploy/deployment.yaml")" == "$image@$image_digest" ]] || return 1
  [[ "$(yq '.spec.template.spec.containers[] | select(.name == "sidecar") | .image' "$ws/deploy/deployment.yaml")" == ghcr.io/devantler-tech/sidecar:1.0.0 ]] || return 1
  grep -qF "image: $image@$image_digest" "$state/pushed-tree" || return 1
  [[ "$(action_output image-digest)" == "$image_digest" ]]
}
case_deployment "$action_dir" || fail "deployment publication changed: $(cat "$calls") $(cat "$log")"
echo 'ok   deployment mode builds to staging, pins, stages, signs, verifies as the caller and only then exposes'

# Each committed layout: deploy-path | app-manifest | the file that must be pinned.
for entry in "flat-beside-base||deployment.yaml" "split|base/deployment.yaml|base/deployment.yaml" \
  "nested|overlays/base/deployment.yaml|overlays/base/deployment.yaml" "renamed|app.yaml|app.yaml" \
  "k8s|base/deployment.yaml|base/deployment.yaml"; do
  IFS='|' read -r deploy manifest at <<<"$entry"
  setup_case "$released"
  set_input deploy-path "./$deploy"
  [[ -z "$manifest" ]] || set_input app-manifest "$manifest"
  published "$action_dir" 1.2.3 latest || fail "refused app-manifest '$manifest' in ./$deploy: $(cat "$log")"
  pinned="$(yq '.spec.template.spec.containers[] | select(.name == "app") | .image' "$ws/$deploy/$at")"
  [[ "$pinned" == "ghcr.io/devantler-tech/app@$image_digest" ]] || fail "did not pin ./$deploy/$at: $pinned"
  if [[ -z "$manifest" ]]; then
    [[ "$(yq '.spec.template.spec.containers[0].image' "$ws/$deploy/base/deployment.yaml")" == ghcr.io/devantler-tech/app:placeholder ]] ||
      fail 'the default pinned a base/ manifest nobody named'
  fi
  grep -qF -- "--path=./$deploy " "$calls" || fail "did not push the whole ./$deploy directory"
done
echo 'ok   app-manifest names the pinned manifest inside deploy-path; the whole deploy-path is published'

setup_case "$released"
sim_repository=Devantler-Tech/App
published "$action_dir" 1.2.3 latest || fail "refused a mixed-case repository: $(cat "$log")"
grep -qF 'image push ghcr.io/devantler-tech/app:staging-123-2 ' "$calls" || fail 'the image name is not lowercase'
grep -qF -- '--certificate-identity https://github.com/Devantler-Tech/App/.github/workflows/release.yaml@refs/tags/v1.2.3 ' "$calls" ||
  fail 'the verified identity is not the exact calling workflow ref'

case_prebuilt() {
  local image=ghcr.io/devantler-tech/app setting
  setup_case "$released"
  for setting in "${prebuilt_ok[@]}"; do set_input "${setting%%=*}" "${setting#*=}"; done
  published "$1" 1.2.3 latest || return 1
  verified_before_exposed 2 || return 1
  ! grep -q '^image push' "$calls" || return 1
  # The original main-CI signature and provenance are read before the first registry write.
  local first_write
  first_write="$(grep -nE '^(flux push|cosign sign)' "$calls" | head -n 1 | cut -d: -f1)"
  [[ "$(grep -n '^read original-provenance' "$calls" | cut -d: -f1)" -lt "$first_write" ]] || return 1
  grep -qE "^cosign sign .*-a devantler.public-digest=$public_digest .* $image@$image_digest$" "$calls" || return 1
  grep -qF -- '-a devantler.image-producer=https://github.com/devantler-tech/app/.github/workflows/ci.yaml@refs/heads/main ' "$calls" || return 1
  [[ "$(yq 'select(.kind == "WebApp") | .spec.image' "$ws/deploy/webapp.yaml")" == "$image@$image_digest" ]] || return 1
  [[ "$(yq '.spec.template.spec.containers[0].image' "$ws/deploy/deployment.yaml")" == "$image:placeholder" ]] || return 1
  [[ "$(action_output image-digest)" == "$image_digest" ]]
}
case_prebuilt "$action_dir" || fail "prebuilt-webapp publication changed: $(cat "$calls") $(cat "$log")"
echo 'ok   prebuilt-webapp mode verifies the main-CI image, pins the WebApp and re-signs it as the caller'

case_manifests() { # <action-dir> <oci-name> <artifact>
  setup_case "$tip"
  set_input mode manifests
  unset_input app-name
  [[ -z "$2" ]] || set_input oci-name "$2"
  published "$1" 1.2.3 latest || return 1
  verified_before_exposed 1 || return 1
  ! grep -qE '^(image push|docker)' "$calls" || return 1
  [[ "$(grep -c '^cosign sign' "$calls")" == 1 ]] || return 1
  grep -qE "^cosign sign .* $3@$artifact_digest$" "$calls" || return 1
  ! grep -qF 'devantler.image-digest' "$calls" || return 1
  [[ "$(grep -c "^read https://ghcr.io/v2/${3#ghcr.io/}/manifests/1.2.3$" "$calls")" == 3 ]] || return 1
  [[ -z "$(action_output image-digest)" ]] || return 1
  [[ "$(yq '.spec.template.spec.containers[0].image' "$ws/deploy/deployment.yaml")" == ghcr.io/devantler-tech/app:placeholder ]]
}
case_manifests "$action_dir" '' ghcr.io/devantler-tech/app/manifests || fail "manifests mode changed: $(cat "$calls") $(cat "$log")"
case_manifests "$action_dir" Devantler-Tech/GitHub-Config ghcr.io/devantler-tech/github-config/manifests ||
  fail "manifests mode ignored oci-name: $(cat "$calls") $(cat "$log")"
echo 'ok   manifests mode publishes only the signed manifests, under oci-name when given'

# ---- 6. nothing is exposed unless both signatures verify ----------------------------------------

case_fault() { # <action-dir> <fault> <reason> [mode]
  setup_case "$released"
  FAULT="$2"
  if [[ "${4:-}" == manifests ]]; then set_input mode manifests; unset_input app-name; fi
  nothing_exposed "$1" || return 1
  grep -qF -- "$3" "$log"
}
case_fault "$action_dir" verify-image 'does not verify as https://github.com/devantler-tech/app/.github/workflows/release.yaml@refs/tags/v1.2.3' ||
  fail "exposed an image whose signature does not verify: $(cat "$calls")"
case_fault "$action_dir" verify-artifact 'does not verify' || fail "exposed manifests whose signature does not verify: $(cat "$calls")"
case_fault "$action_dir" verify-artifact 'does not verify' manifests || fail "manifests mode exposed an unverified artifact: $(cat "$calls")"
case_fault "$action_dir" registry-raced 'already exists' || fail "exposed a version that appeared after verification: $(cat "$calls")"
case_fault "$action_dir" copy-mismatch 'the image copy changed the verified digest' || fail "exposed a changed image copy: $(cat "$calls")"
case_fault "$action_dir" no-artifact-digest 'did not report the pushed artifact digest' || fail 'signed without an artifact digest'
grep -q '^cosign' "$calls" && fail 'signed or verified without an artifact digest'
echo 'ok   a failed verification, copy or late version exposes nothing'

# Across every unmutated run above, no program a step ran received the token or its encoded header.
for program in curl git flux cosign; do
  grep -q "^$program " "$argv_all" || fail "the argv record never saw $program"
done
grep -q '^git fetch ' "$argv_all" || fail 'the argv record never saw the default-branch fetch'
! grep -qF -- "$token" "$argv_all" || fail "a program received the token as an argument: $(grep -F -- "$token" "$argv_all" | head -n 3)"
! grep -qF -- "${token_header#AUTHORIZATION: basic }" "$argv_all" || fail 'a program received the encoded token header as an argument'
echo 'ok   no program any step ran received the token or its encoded header as an argument'

# ---- 7. mutation controls: every guard must matter ------------------------------------------------

mutating=true
case_prerelease() {
  setup_case "$released"
  sim_ref=refs/tags/v1.2.3-rc.1
  published "$1" 1.2.3-rc.1
}
case_prerelease "$action_dir" || fail "a prerelease moved latest: $(cat "$calls")"

# copy_action <file> <sed expression> — a copy of the catalogue with one action file edited, in
# $copy_dir. The copy resolves the shared scripts exactly as the published action does.
copy_action() {
  copy_dir="$(mktemp -d "$scratch/mutant.XXXXXX")"
  mkdir -p "$copy_dir/actions"
  cp -R "$action_dir" "$copy_dir/actions/publish-app"
  ln -s "$root/.github" "$copy_dir/.github"
  ln -s "$root/.scripts" "$copy_dir/.scripts"
  sed "$2" "$action_dir/$1" >"$copy_dir/actions/publish-app/$1"
  ! cmp -s "$action_dir/$1" "$copy_dir/actions/publish-app/$1" || fail "edit did not apply to $1: $2"
  copy_dir="$copy_dir/actions/publish-app"
}

# Control: copies made this way, with a no-op edit to each file, still hold every case below, so a
# mutant fails only because of its own edit.
for edit in 'admit.sh|s/^set -euo pipefail$/set -euo pipefail # control/' \
  'publish.sh|s/^set -euo pipefail$/set -euo pipefail # control/' \
  'require-unpublished.sh|s/^set -euo pipefail$/set -euo pipefail # control/' \
  'action.yaml|s/^author: devantler-tech$/author: devantler-tech # control/'; do
  copy_action "${edit%%|*}" "${edit#*|}"
  if ! { case_ref "$copy_dir" refs/heads/main 'must run on a release tag' &&
    case_ref "$copy_dir" refs/tags/v1.2.3garbage 'complete semantic version' &&
    case_ref "$copy_dir" refs/tags/v9007199254740992.0.0 'numbers of at most 15 digits' &&
    case_identity "$copy_dir" "devantler-tech/app/.github/workflows/release.yaml@refs/heads/main" "$belong" &&
    case_head_moved "$copy_dir" && case_outer "$copy_dir" && case_persisted "$copy_dir" direct &&
    case_not_on_default "$copy_dir" && case_undeterminable "$copy_dir" "file://$scratch/nowhere" &&
    case_no_commit "$copy_dir" && case_ancestry_error "$copy_dir" && case_one_header "$copy_dir" &&
    case_deploy_link "$copy_dir" && case_linked_contents "$copy_dir" deployment &&
    case_source "$copy_dir" modified "$differs" && case_source "$copy_dir" untracked "$untracked" &&
    case_manifest "$copy_dir" deployment linked-file 'app-manifest passes through a link' &&
    case_manifest "$copy_dir" deployment ../deployment.yaml "$plain_manifest" &&
    case_containers "$copy_dir" ambiguous "expected exactly one container named 'app'" &&
    case_occupied "$copy_dir" registry-existing && case_raced_after_build "$copy_dir" &&
    case_fault "$copy_dir" registry-raced 'already exists' && case_fault "$copy_dir" verify-image 'does not verify' &&
    case_fault "$copy_dir" verify-artifact 'does not verify' && case_fault "$copy_dir" copy-mismatch 'changed the verified digest' &&
    case_fault "$copy_dir" verify-artifact 'does not verify' manifests &&
    case_deployment "$copy_dir" && case_manifests "$copy_dir" '' ghcr.io/devantler-tech/app/manifests &&
    case_prerelease "$copy_dir"; }; then
    fail "an unmutated copy (${edit%%|*}) no longer holds: $(cat "$log")"
  fi
done
echo 'ok   unmutated copies hold every mutation case'

# must_catch <description> <action file> <sed expression> <case function> [case args...]
# Applies one portable sed edit to a fresh copy of the action and requires the case to stop holding.
must_catch() {
  local description="$1" case_fn="$4"
  copy_action "$2" "$3"
  shift 4
  if "$case_fn" "$copy_dir" "$@" >/dev/null 2>&1; then fail "mutation not caught: $description"; fi
  echo "ok   caught: $description"
}

must_catch 'branch refs admitted' admit.sh 's/\[\[ "\$ref" == refs\/tags\/\* \]\] || fail/[[ "$ref" == refs\/tags\/* ]] || true/' \
  case_ref refs/heads/main 'must run on a release tag'
must_catch 'non-semver tags admitted' admit.sh 's/\[\[ "\$tag" =~ \$semver \]\] || fail/true || fail/' \
  case_ref refs/tags/v1.2.3garbage 'complete semantic version'
must_catch 'unreadable version numbers admitted' admit.sh 's/ || "\$numbers" =~ \$too_long//' \
  case_ref refs/tags/v9007199254740992.0.0 'numbers of at most 15 digits'
must_catch 'a foreign signer identity admitted' admit.sh 's/^check_signer_identity$/:/' \
  case_identity "devantler-tech/app/.github/workflows/release.yaml@refs/heads/main" "$belong"
must_catch 'a different checkout admitted' admit.sh 's/^check_checkout$/:/' case_head_moved
must_catch 'a checkout below the workspace root admitted' admit.sh 's/\[\[ "\$(git rev-parse --show-toplevel 2>\/dev\/null)" -ef \. \]\] ||/true ||/' \
  case_outer
must_catch 'a persisted checkout credential admitted' admit.sh "s/    0) fail 'the checkout persisted/    0) : 'the checkout persisted/" \
  case_persisted direct
must_catch 'tags outside the default branch admitted' admit.sh 's/    1) fail "tag/    1) : "tag/' case_not_on_default
must_catch 'the default-branch check removed' admit.sh 's/^check_default_branch$/:/' case_not_on_default
must_catch 'an undeterminable default branch admitted' admit.sh 's/fail "cannot determine/: "cannot determine/g' \
  case_undeterminable "file://$scratch/nowhere"
must_catch 'a fetched default branch without a commit passed' admit.sh \
  's/    fail "cannot determine whether \$GITHUB_SHA is on the default branch: no default branch commit was fetched"/    : no commit/' \
  case_no_commit
must_catch 'an unanswered ancestry check passed' admit.sh \
  's/    \*) fail "cannot determine whether \$GITHUB_SHA is on the default branch (git exit \$status)" ;;/    *) ;;/' \
  case_ancestry_error
must_catch 'the inherited fetch header not reset' admit.sh \
  '/GIT_CONFIG_VALUE_0=.. \\$/s/_0=/_9=/g; s/GIT_CONFIG_KEY_1=/GIT_CONFIG_KEY_0=/; s/GIT_CONFIG_VALUE_1=/GIT_CONFIG_VALUE_0=/; s/GIT_CONFIG_COUNT=2/GIT_CONFIG_COUNT=1/' \
  case_one_header
must_catch 'a linked deploy-path admitted' admit.sh 's/\[\[ ! -L "\$cursor" \]\] || fail/true || fail/' case_deploy_link
must_catch 'a linked app-manifest admitted' admit.sh 's/\[\[ ! -L "\$cursor" \]\] || fail/true || fail/' \
  case_manifest deployment linked-file 'app-manifest passes through a link'
must_catch 'links inside deploy-path admitted' admit.sh 's/^check_deploy_contents$/:/' case_linked_contents deployment
must_catch 'links inside a manifests-only deploy-path admitted' admit.sh 's/^check_deploy_contents$/:/' case_linked_contents manifests
must_catch 'a changed deploy-path admitted' admit.sh 's/    1) fail "deploy-path/    1) : "deploy-path/' case_source modified "$differs"
must_catch 'untracked deploy-path files admitted' admit.sh 's/\[\[ -z "\$untracked" \]\] || fail/true || fail/' \
  case_source untracked "$untracked"
must_catch 'an unsafe app-manifest admitted' admit.sh 's/^  \[\[ "\$manifest" =~ .* \]\] ||$/  true ||/' \
  case_manifest deployment ../deployment.yaml "$plain_manifest"
must_catch 'an ambiguous app container admitted' admit.sh 's/\[\[ "\$matches" == 1 \]\] || fail/true || fail/' \
  case_containers ambiguous "expected exactly one container named 'app'"
must_catch 'the pre-build version check removed' action.yaml \
  '/- name: 🔒 Refuse an occupied release version/,/run: bash "\$GITHUB_ACTION_PATH\/require-unpublished.sh"/d' \
  case_occupied registry-existing
must_catch 'the pre-staging version check removed' publish.sh 's/^require_unpublished before-staging$/:/' case_raced_after_build
must_catch 'the pre-exposure version check removed' publish.sh 's/^require_unpublished before-exposure$/:/' \
  case_fault registry-raced 'already exists'
must_catch 'verification removed' publish.sh 's/^verify$/:/' case_fault verify-image 'does not verify'
must_catch 'verification moved after exposure' publish.sh 's/^verify$/:/; s/^expose$/expose; verify/' \
  case_fault verify-artifact 'does not verify'
must_catch 'a foreign verification identity' publish.sh \
  's|^identity=.*|identity="https://github.com/devantler-tech/.github/.github/workflows/publish-app.yaml@refs/heads/main"|' case_deployment
must_catch 'the image copy check removed' publish.sh 's/^check_copy$/:/' case_fault copy-mismatch 'changed the verified digest'
must_catch 'the digest pin removed' publish.sh 's/|| pin_image$/|| :/' case_deployment
must_catch 'prereleases moving latest' publish.sh 's/ || "\$VERSION" != \*-\* \]\]/ || true ]]/' case_prerelease
must_catch 'manifests mode exposing an unverified artifact' publish.sh 's/^verify$/:/' \
  case_fault verify-artifact 'does not verify' manifests
must_catch 'the token back in the flux push arguments' publish.sh \
  's/^    --output json)"$/    --creds "$GITHUB_ACTOR:$GH_TOKEN" --output json)"/' case_deployment
must_catch 'the token back in the flux tag arguments' publish.sh \
  's/ --tag "\$pointer"$/ --tag "$pointer" --creds "$GITHUB_ACTOR:$GH_TOKEN"/' case_manifests '' ghcr.io/devantler-tech/app/manifests
must_catch 'the token back in the curl arguments' require-unpublished.sh \
  's/--config "\$work\/login.curlrc"/--user "$GITHUB_ACTOR:$GH_TOKEN"/' case_deployment

echo 'PASS: publish-app admits only default-branch release tags, refuses before any registry contact, keeps the token off every command line and exposes only verified releases'
