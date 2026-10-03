#!/usr/bin/env bash
# Execute the action's real Docker wrapper and pinned image with network access disabled.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$root/.github/tests/todo-scanner"
cases="$fixture/cases.json"
check_only=false
if (( $# > 0 )); then
  [[ $# == 2 && ( "$1" == --check-fixtures || "$1" == --cases ) ]] || {
    echo 'usage: test-todo-scanner.sh [--check-fixtures file | --cases file]' >&2; exit 2;
  }
  [[ "$1" != --check-fixtures ]] || check_only=true
  cases="$2"
fi
jq -e '
  def valid_exchange:
    type == "object" and (.Method | IN("GET", "POST", "PATCH")) and
    (.Path | type == "string" and startswith("/")) and
    (.Status | type == "number" and floor == . and . >= 100 and . <= 599) and
    (.Response | type == "string") and
    (if has("Body") then .Body | type == "string" else true end);
  type == "array" and length > 0 and ([.[].Name]|unique|length) == length and
  all(.[];
    (.Name|type == "string" and length > 0) and
    (.Files|type == "object" and length > 0) and
    (.Files|keys|all(test("^[A-Za-z0-9._/-]+$") and (startswith("/")|not) and
      (split("/")|all(. != ".." and . != "." and . != "")))) and
    all(.Files[]; (.Before|type == "string") and (.After|type == "string")) and
    (.Operations|type == "array" and all(valid_exchange)) and
    (.Output|type == "array" and all(type == "string" and length > 0)) and
    (if has("Ignore") then .Ignore|type == "string" else true end) and
    (if has("ExcludeVendored") then .ExcludeVendored|IN("true","false") else true end) and
    (if has("WantFailure") then .WantFailure|type == "boolean" else true end) and
    (if has("ForbiddenOutput") then .ForbiddenOutput|type == "array" and all(type == "string" and length > 0) else true end) and
    (if has("InitialReads") then .InitialReads|type == "array" and length > 0 and all(valid_exchange and .Method == "GET") else true end))
  ' "$cases" >/dev/null || { echo 'Invalid scanner scenarios' >&2; exit 1; }
[[ "$check_only" == false ]] || exit 0
export TODO_REAL_DOCKER
TODO_REAL_DOCKER="$(command -v docker)"
[[ "$TODO_REAL_DOCKER" == /* ]] || { echo 'FAIL: real Docker is required' >&2; exit 1; }
yq -o=json '.' "$root/actions/create-issues-from-todos/action.yaml" >"$work/action.json"
jq -er '.runs.steps[] | select(.name == "📝 Create issues from TODOs") | .run' "$work/action.json" >"$work/scanner.sh"
image="$(jq -er '.runs.steps[] | select(.name == "📝 Create issues from TODOs") | .env.TODO_TO_ISSUE_IMAGE' "$work/action.json")"
[[ "$image" =~ ^ghcr.io/alstr/todo-to-issue-action:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] || {
  echo 'FAIL: immutable scanner image is required' >&2; exit 1;
}
# Pull before the disposable container loses its network. No registry credentials.
bash "$root/.scripts/retry.sh" docker pull "$image"
(cd "$fixture" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$work/runner" .)
mkdir -p "$work/bin" "$work/temp"
cp "$root/.scripts/retry.sh" "$work/temp/devantler-actions-retry.sh"
cat >"$work/bin/docker" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || { echo 'Only scanner execution is allowed' >&2; exit 1; }
shift
exec "$TODO_REAL_DOCKER" run --platform linux/amd64 --pull never --network none \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --mount "type=bind,src=${TODO_CASE_DIR:?},dst=/fixture,readonly" \
  --entrypoint /fixture/runner "$@"
SHIM
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH" RUNNER_TEMP="$work/temp" RETRY_MAX_ATTEMPTS=1

count="$(jq 'length' "$cases")"
for ((i=0; i<count; i++)); do
  export TODO_CASE_DIR="$work/case-$i" GITHUB_WORKSPACE="$work/case-$i/workspace"
  mkdir -p "$GITHUB_WORKSPACE"
  cp "$work/runner" "$TODO_CASE_DIR/runner"
  jq ".[$i]" "$cases" >"$TODO_CASE_DIR/source.json"
  jq -r '.Files | keys[]' "$TODO_CASE_DIR/source.json" >"$TODO_CASE_DIR/files"
  # A real Git diff provides scanner input; issue payload expectations remain literal.
  git -C "$GITHUB_WORKSPACE" init -q
  git -C "$GITHUB_WORKSPACE" config user.name offline-fixture
  git -C "$GITHUB_WORKSPACE" config user.email offline@example.invalid
  while IFS= read -r file; do
    mkdir -p "$GITHUB_WORKSPACE/$(dirname "$file")"
    jq -jr --arg file "$file" '.Files[$file].Before' "$TODO_CASE_DIR/source.json" >"$GITHUB_WORKSPACE/$file"
    git -C "$GITHUB_WORKSPACE" add -- "$file"
  done <"$TODO_CASE_DIR/files"
  git -C "$GITHUB_WORKSPACE" -c commit.gpgsign=false commit -qm fixture
  while IFS= read -r file; do
    jq -jr --arg file "$file" '.Files[$file].After' "$TODO_CASE_DIR/source.json" >"$GITHUB_WORKSPACE/$file"
  done <"$TODO_CASE_DIR/files"
  git -C "$GITHUB_WORKSPACE" diff --no-ext-diff --no-color >"$TODO_CASE_DIR/diff"
  jq --rawfile diff "$TODO_CASE_DIR/diff" -f "$fixture/plan.jq" "$TODO_CASE_DIR/source.json" >"$TODO_CASE_DIR/case.json"
  ignore="$(bash "$root/.github/tests/todo-ignore-resolution.sh" "$work/action.json" "$TODO_CASE_DIR/source.json")"
  jq -n --arg ignore "$ignore" '{
    "${{ github.repository }}":"offline/fixture",
    "${{ github.event.before || github.base_ref }}":"fixture-base",
    "${{ toJSON(github.event.commits) }}":"null",
    "${{ github.event.pull_request.diff_url }}":"",
    "${{ github.sha }}":"1111111111111111111111111111111111111111",
    "${{ github.token }}":"offline-token",
    "${{ inputs.project }}":"",
    "${{ steps.app-token.outputs.token }}":"",
    "${{ github.actor }}":"offline-actor",
    "${{ github.api_url }}":"https://api.example.invalid",
    "${{ github.server_url }}":"https://example.invalid",
    "${{ inputs.ignore || steps.vendored-ignore.outputs.ignore }}":$ignore}' >"$TODO_CASE_DIR/context.json"
  jq -e --slurpfile context "$TODO_CASE_DIR/context.json" '
    .runs.steps[] | select(.name == "📝 Create issues from TODOs") | .env |
    with_entries(.value = (.value | tostring | . as $value |
      if startswith("${{") then
        if $context[0] | has($value) then $context[0][$value]
        else error("unmapped action expression") end
      else . end))' "$work/action.json" >"$TODO_CASE_DIR/env.json"
  jq -j 'to_entries[] | .key,"\u0000",.value,"\u0000"' "$TODO_CASE_DIR/env.json" >"$TODO_CASE_DIR/env"
  if ! (
    while IFS= read -r -d '' key && IFS= read -r -d '' value; do export "$key=$value"; done <"$TODO_CASE_DIR/env"
    bash "$work/scanner.sh"
  ) >"$TODO_CASE_DIR/result" 2>&1; then
    cat "$TODO_CASE_DIR/result"
    exit 1
  fi
  cat "$TODO_CASE_DIR/result"
  name="$(jq -r .Name "$TODO_CASE_DIR/case.json")"
  requests="$(jq '.Exchanges | length' "$TODO_CASE_DIR/case.json")"
  bash "$root/.github/tests/todo-scanner-verdict.sh" "$TODO_CASE_DIR/result" "$name" "$requests"
done
echo "PASS: $count real pinned scanner scenarios with no network"
