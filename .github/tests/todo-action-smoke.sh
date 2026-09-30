#!/usr/bin/env bash
# Offline Docker stand-in for the action's wrapper; it does not parse source comments.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="${RUNNER_TEMP:?}/todo-action-smoke"
case "${1:-}" in
  prepare)
    mkdir -p "$fixture/bin"
    : >"$fixture/calls.jsonl"
    [[ -n "${TODO_EXPECTED_TOKEN:-}" ]] || { echo 'Missing expected read-only fixture token' >&2; exit 1; }
    jq -n --arg token "$TODO_EXPECTED_TOKEN" --arg secret "${TODO_EXPECTED_PROJECT_SECRET:-}" \
      '{INPUT_TOKEN:$token,INPUT_PROJECTS_SECRET:$secret}' >"$fixture/credentials.json"
    chmod 600 "$fixture/credentials.json"
    image="$(yq -r '.runs.steps[] | select(.name == "📝 Create issues from TODOs") | .env.TODO_TO_ISSUE_IMAGE' "$root/actions/create-issues-from-todos/action.yaml")"
    jq -n --arg image "$image" --arg workspace "${GITHUB_WORKSPACE:?}" \
      --arg repo "${GITHUB_REPOSITORY:?}" --arg before "${TODO_EXPECTED_BEFORE:-}" \
      --arg commits "${TODO_EXPECTED_COMMITS:-null}" --arg diff "${TODO_EXPECTED_DIFF:-}" \
      --arg sha "${GITHUB_SHA:?}" --arg actor "${GITHUB_ACTOR:?}" \
      --arg api "${GITHUB_API_URL:?}" --arg server "${GITHUB_SERVER_URL:?}" \
      --arg project "${TODO_EXPECTED_PROJECT:-}" --arg secret "${TODO_EXPECTED_PROJECT_SECRET:-}" \
      --arg ignore "${TODO_EXPECTED_IGNORE:-}" '
      {args:(["run","--rm","--workdir","/github/workspace","--volume",($workspace+":/github/workspace"),
        "--env","GITHUB_ACTIONS=true","--env","GITHUB_WORKSPACE=/github/workspace","--env","CI=true"]
        + (["INPUT_REPO","INPUT_BEFORE","INPUT_COMMITS","INPUT_DIFF_URL","INPUT_SHA","INPUT_TOKEN",
          "INPUT_CLOSE_ISSUES","INPUT_AUTO_P","INPUT_PROJECT","INPUT_PROJECTS_SECRET","INPUT_AUTO_ASSIGN",
          "INPUT_ACTOR","INPUT_GITHUB_URL","INPUT_GITHUB_SERVER_URL","INPUT_ESCAPE","INPUT_NO_STANDARD",
          "INPUT_INSERT_ISSUE_URLS","INPUT_IGNORE"] | map(["--env",.]) | add) + [$image]),
       env:{GITHUB_ACTIONS:"true",GITHUB_WORKSPACE:"/github/workspace",CI:"true",
         INPUT_REPO:$repo,INPUT_BEFORE:$before,INPUT_COMMITS:$commits,INPUT_DIFF_URL:$diff,
         INPUT_SHA:$sha,INPUT_TOKEN:"<present>",INPUT_CLOSE_ISSUES:"true",INPUT_AUTO_P:"true",
         INPUT_PROJECT:$project,INPUT_PROJECTS_SECRET:(if $secret == "" then "" else "<present>" end),INPUT_AUTO_ASSIGN:"true",
         INPUT_ACTOR:$actor,INPUT_GITHUB_URL:$api,INPUT_GITHUB_SERVER_URL:$server,
         INPUT_ESCAPE:"true",INPUT_NO_STANDARD:"false",INPUT_INSERT_ISSUE_URLS:"false",INPUT_IGNORE:$ignore}}' \
      >"$fixture/expected.json"
    cat >"$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
fixture="${RUNNER_TEMP:?}/todo-action-smoke"
args="$(jq -cn --args '$ARGS.positional' -- "$@")"
pairs=()
while (( $# )); do
  if [[ "$1" == --env ]]; then
    shift
    entry="${1:?missing environment argument}"
    key="${entry%%=*}"
    if [[ "$entry" == *=* ]]; then value="${entry#*=}"
    else value="${!key-}"
    fi
    if [[ "$key" == INPUT_TOKEN || "$key" == INPUT_PROJECTS_SECRET ]]; then
      expected="$(jq -r --arg key "$key" '.[$key]' "$fixture/credentials.json")"
      [[ "$value" == "$expected" ]] || { echo 'Offline credential forwarding differs' >&2; exit 74; }
      [[ -z "$value" ]] || value="<present>"
    fi
    pairs+=("$key" "$value")
  fi
  shift
done
jq -cn --argjson args "$args" --args '
  $ARGS.positional as $pairs | {args:$args,env:
    (reduce range(0; ($pairs|length); 2) as $i ({}; .[$pairs[$i]]=$pairs[$i+1]))}' \
  -- "${pairs[@]}" >>"$fixture/calls.jsonl"
attempts="$(wc -l <"$fixture/calls.jsonl")"
if (( ${TODO_FAILURES:-0} < 0 || attempts <= ${TODO_FAILURES:-0} )); then
  echo 'Offline Docker fixture failed' >&2
  exit 73
fi
MOCK
    chmod +x "$fixture/bin/docker"
    printf '%s\n' "$fixture/bin" >>"${GITHUB_PATH:?}"
    ;;
  verify)
    jq -e --slurpfile expected "$fixture/expected.json" --argjson count "${TODO_EXPECTED_ATTEMPTS:-1}" \
      -s 'length == $count and all(. == $expected[0])' "$fixture/calls.jsonl" >/dev/null || {
      echo 'FAIL: Docker attempts, arguments or forwarded inputs differ' >&2
      exit 1
    }
    rm -f "$fixture/credentials.json"
    echo 'PASS: actual to-do action wrapper stays in the offline Docker fixture'
    ;;
  *) echo 'usage: todo-action-smoke.sh <prepare|verify>' >&2; exit 2 ;;
esac
