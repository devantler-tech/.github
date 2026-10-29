#!/usr/bin/env bash
# Execute the pinned stale action against the catalogue's loopback API fixture.
# prepare -> native composite action -> verify. No live token or write authority.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="${RUNNER_TEMP:?}/stale-issues-offline"
fail() { echo "stale-issues test: $*" >&2; exit 1; }

case "${1:-}" in
labels)
  label_work="$(mktemp -d)"
  trap 'rm -rf "$label_work"' EXIT
  yq -r '.jobs.triage.steps[] | select(.id == "labels-ready") | .run' \
    "$root/.github/workflows/triage-stale-issues.yaml" >"$label_work/guard"
  [[ -s "$label_work/guard" ]] || fail 'live label-readiness guard is missing'
  mkdir "$label_work/bin"
  cat >"$label_work/bin/gh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && $1 == api && $2 == repos/offline/fixture/labels/* ]] || exit 99
name=${2##*/}
case "$name" in stale) color=ededed ;; keep-open) color=0e8a16 ;; *) exit 98 ;; esac
case "$LABEL_FIXTURE" in
  missing-stale) [[ "$name" != stale ]] || exit 1 ;;
  missing-keep-open) [[ "$name" != keep-open ]] || exit 1 ;;
  wrong-name) name=another-label ;;
  wrong-color) color=000000 ;;
  malformed) printf '%s\n' 'not json'; exit 0 ;;
esac
jq -n --arg name "$name" --arg color "$color" '{name:$name,color:$color}'
BASH
  chmod +x "$label_work/bin/gh"
  for fixture in good missing-stale missing-keep-open wrong-name wrong-color malformed; do
    rc=0
    PATH="$label_work/bin:$PATH" REPOSITORY=offline/fixture GH_TOKEN=offline-fixture \
      LABEL_FIXTURE="$fixture" bash "$label_work/guard" >"$label_work/result" 2>&1 || rc=$?
    if [[ "$fixture" == good ]]; then
      [[ "$rc" == 0 ]] || { cat "$label_work/result" >&2; fail 'valid deployed labels were refused'; }
    else
      [[ "$rc" != 0 ]] || fail "accepted unproven label readiness: $fixture"
    fi
  done
  echo 'PASS: live activation requires both exact managed label definitions'
  ;;
prepare)
  [[ -f "$root/actions/triage-stale-issues/action.yaml" ]] || fail 'shared stale action is missing'
  [[ ! -e "$work" ]] || fail 'fixture directory already exists'
  mkdir -p "$work"
  jq -n '
    def ago($days): (now - $days * 86400 | todateiso8601);
    def issue($n;$days;$type;$labels): {
      id:$n,number:$n,title:("Fixture " + ($n|tostring)),state:"open",locked:false,
      created_at:ago(200),updated_at:ago($days),type:{name:$type},
      labels:($labels | map({name:.})),assignees:[],milestone:null,
      user:{login:"fixture-author",type:"User"},comments:0
    };
    def route($method;$path;$query;$body): {
      method:$method,path:$path,query:$query,status:200,body:$body
    };
    [issue(1;91;"Bug";[]),issue(2;31;"Feature";["stale"]),
     issue(3;29;"Chore";["stale"]),issue(4;1;"Bug";["stale"]),
     issue(5;150;"Epic";[]),issue(6;150;"Security";[]),
     issue(7;150;"Feature";["blocked"]),issue(8;150;"Feature";["keep-open"]),
     issue(9;150;"Chore";["maintainer-ask"]),
     (issue(10;150;"Bug";[]) + {pull_request:{url:"https://example.invalid/pulls/10"}}),
     issue(11;89;"Bug";[]),issue(12;150;"Chore";["maintainer-ask-urgent"]),
     (issue(13;150;"Feature";[]) | del(.type))] as $issues |
    {routes:([
      route("GET";"/rate_limit";{};{rate:{limit:5000,used:0,remaining:5000,reset:(now+3600|floor)}}),
      route("GET";"/repos/offline/fixture/actions/caches";{key:"_state"};{total_count:0,actions_caches:[]}),
      route("GET";"/repos/offline/fixture/issues";
        {state:"open",per_page:"100",direction:"asc",sort:"updated",page:"1"};$issues),
      route("GET";"/repos/offline/fixture/issues";
        {state:"open",per_page:"100",direction:"asc",sort:"updated",page:"2"};[]),
      route("POST";"/repos/offline/fixture/issues/1/comments";{};{id:101}),
      route("POST";"/repos/offline/fixture/issues/1/labels";{};[{name:"stale"}]),
      route("POST";"/repos/offline/fixture/issues/2/comments";{};{id:102}),
      route("PATCH";"/repos/offline/fixture/issues/2";{};{state:"closed",state_reason:"not_planned"}),
      route("DELETE";"/repos/offline/fixture/issues/4/labels/stale";{};[])
    ] + [range(1;5) as $n |
      route("GET";("/repos/offline/fixture/issues/"+($n|tostring)+"/events");{per_page:"100"};
        if $n==1 then [] else [{event:"labeled",label:{name:"stale"},created_at:ago(if $n==3 then 29 else 31 end)}] +
        (if $n==4 then [{event:"commented",created_at:ago(1)}] else [] end) end),
      route("GET";("/repos/offline/fixture/issues/"+($n|tostring)+"/comments");{};
        if $n==4 then [{id:104,body:"Still needed",created_at:ago(1),user:{login:"fixture-maintainer",type:"User"}}] else [] end)
    ])}
  ' >"$work/scenario.json"
  printf '%s\n' '{"repository":{"owner":{"login":"offline"},"name":"fixture","full_name":"offline/fixture"}}' >"$work/event.json"
  : >"$work/blocked-hosts"
  : >"$work/action.log"
  : >"$work/action-output"
  nonce="stale-$$-$(date +%s)"
  printf '%s' "$nonce" >"$work/nonce"
  go build -o "$work/api" "$root/.github/tests/fixtures/offline-github-api/main.go"
  "$work/api" -scenario "$work/scenario.json" -record "$work/requests.jsonl" \
    -address-file "$work/address" -token offline-fixture-token \
    -completion-file "$work/completed.json" -nonce "$nonce" >"$work/api.log" 2>&1 &
  printf '%s\n' "$!" >"$work/pid"
  for _ in {1..100}; do
    [[ -s "$work/address" ]] && break
    kill -0 "$(cat "$work/pid")" 2>/dev/null || { cat "$work/api.log" >&2; fail 'API fixture stopped'; }
    sleep 0.05
  done
  [[ -s "$work/address" ]] || fail 'API fixture did not start'
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'api-url=%s\n' "$(cat "$work/address")"
      printf 'event-path=%s/event.json\n' "$work"
      printf 'blocked-hosts-file=%s/blocked-hosts\n' "$work"
      printf 'action-log-file=%s/action.log\n' "$work"
    } >>"$GITHUB_OUTPUT"
  fi
  echo 'stale-issues test: loopback fixture prepared (13 independent issue/PR cases)'
  ;;
verify)
  pid="$(cat "$work/pid")"
  [[ "$pid" =~ ^[0-9]+$ ]] || fail 'invalid fixture process'
  kill -0 "$pid" 2>/dev/null || fail 'API fixture stopped before verification'
  kill "$pid"
  for _ in {1..100}; do
    [[ -s "$work/completed.json" ]] && break
    sleep 0.05
  done
  [[ -s "$work/completed.json" ]] || fail 'API fixture has no clean completion receipt'
  [[ ! -s "$work/blocked-hosts" ]] || fail 'action attempted external network access'
  if grep -q '^::error' "$work/action.log"; then
    cat "$work/action.log" >&2
    fail 'action emitted an error'
  fi
  jq -e --arg nonce "$(cat "$work/nonce")" \
    --arg record "$(shasum -a 256 "$work/requests.jsonl" | cut -d " " -f 1)" \
    --arg scenario "$(shasum -a 256 "$work/scenario.json" | cut -d " " -f 1)" \
    '.nonce==$nonce and .record_sha256==$record and .scenario_sha256==$scenario' \
    "$work/completed.json" >/dev/null || fail 'incomplete or changed fixture evidence'
  jq -se '
    length>0 and all(.[]; .authorized and .route>=0 and .status==200) and
    ([.[]|select(.method!="GET")|{method,path}] == [
      {method:"POST",path:"/repos/offline/fixture/issues/1/comments"},
      {method:"POST",path:"/repos/offline/fixture/issues/1/labels"},
      {method:"POST",path:"/repos/offline/fixture/issues/2/comments"},
      {method:"PATCH",path:"/repos/offline/fixture/issues/2"},
      {method:"DELETE",path:"/repos/offline/fixture/issues/4/labels/stale"}
    ]) and
    all(.[]|select(.method=="POST" and (.path|endswith("/comments")));
      (.body.body|startswith("> 🤖 Generated by the Agentic Engineer")) and
      (.body.body|contains("30")) and
      (if (.path|contains("/1/")) then (.body.body|contains("90"))
       else (.body.body|ascii_downcase|contains("reopen")) end)) and
    all(.[]|select(.method=="PATCH");.body=={state:"closed",state_reason:"not_planned"}) and
    all(.[]|select(.method=="POST" and (.path|endswith("/labels")));.body=={labels:["stale"]})
  ' "$work/requests.jsonl" >/dev/null || {
    jq -c 'select(.method!="GET" or .route<0)|{method,path,status,body}' "$work/requests.jsonl" >&2
    fail '90/30 boundaries, activity recovery, exemptions or request payloads regressed'
  }
  echo 'PASS: 90/30 triage, delayed closure, activity recovery, protected types/labels and PR exclusion'
  ;;
*) fail 'usage: test-triage-stale-issues.sh labels|prepare|verify' ;;
esac
