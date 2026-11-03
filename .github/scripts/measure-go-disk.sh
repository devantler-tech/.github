#!/usr/bin/env bash
# Sample filesystem headroom while preserving the wrapped command's result.
set -euo pipefail
# Only an input-free required Test invocation may consult this module-local data.
# Called false/omitted inputs select disabled mode and read nothing.
select_observation() {
  local module="${1:-}" mode="${2:-}" top current part file inventory record metadata records=0
  case "$mode" in disabled)
    printf 'false\n'
    return
    ;;
  optional) ;; *) return 2 ;; esac
  top="$(git rev-parse --show-toplevel)" || return 2
  [[ "$(pwd -P)" == "$(cd "$top" && pwd -P)" ]] || return 2
  file=.go-disk-observation.json
  if [[ "$module" != . ]]; then
    [[ "$module" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || return 2
    current="$top"
    IFS=/ read -r -a parts <<<"$module"
    for part in "${parts[@]}"; do
      [[ "$part" != . && "$part" != .. && "$part" != .git ]] || return 2
      current="$current/$part"
      [[ -d "$current" && ! -L "$current" ]] || return 2
    done
    file="$module/$file"
  fi
  inventory="$(mktemp)" || return 2
  if ! git ls-files --stage -z -- "$file" >"$inventory"; then
    rm -f -- "$inventory"
    return 2
  fi
  record=''
  # Removing the private inventory on refusal does not change the open reader.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' record; do
    records=$((records + 1))
    metadata="${record%%$'\t'*}"
    if [[ "$records" != 1 || ! "$metadata" =~ ^100644\ ([a-f0-9]{40}|[a-f0-9]{64})\ 0$ ||
      "${record#*$'\t'}" != "$file" ]]; then
      rm -f -- "$inventory"
      return 2
    fi
  done <"$inventory"
  rm -f -- "$inventory"
  [[ -z "$record" ]] || return 2
  if [[ "$records" == 0 ]]; then
    [[ ! -e "$file" && ! -L "$file" ]] || return 2
    printf 'false\n'
    return
  fi
  [[ -f "$file" && -r "$file" && ! -L "$file" && "$(wc -c <"$file")" -le 1024 ]] || return 2
  jq -se 'length == 1 and (.[0] | type == "object" and keys == ["test","version"] and
    .version == 1 and (.test | type == "boolean"))' "$file" >/dev/null 2>&1 || return 2
  jq --stream -se '[.[] | select(length == 2) | .[0]] | sort == [["test"],["version"]]' "$file" >/dev/null 2>&1 || return 2
  jq -r .test "$file"
}
if [[ "${1:-}" == select ]]; then
  shift
  select_observation "$@" || {
    echo 'Invalid Go disk observation declaration' >&2
    exit 2
  }
  exit 0
fi
# Rich observations are restricted to the separately admitted ordinary required
# Test run. Legacy measure-disk-usage callers retain their existing collector.
observation="${GO_DISK_OBSERVATION:-false}"
observation_state="${RUNNER_TEMP:-/tmp}/go-disk-observation"
observation_phase=before-command
observation_components=true
observation_failed=false
readonly -a observation_labels=(root workspace module module-cache build-cache toolchain go-temp runner-temp)
readonly observation_probe_timeout_seconds=2 observation_probe_kill_grace_seconds=1 observation_sample_interval_seconds=1
# Each label has two df reads and up to two stat attempts. Every non-root
# label can also have a du walk; sample() has one initial df read as well.
# Include each probe's TERM-to-KILL grace and bounded process/JSON overhead.
readonly observation_frame_probe_count=$((${#observation_labels[@]} * (2 + 2) + ${#observation_labels[@]} - 1 + 1))
readonly observation_frame_budget_seconds=$((observation_frame_probe_count * (observation_probe_timeout_seconds + observation_probe_kill_grace_seconds) + 10))
readonly observation_stop_budget_seconds=$((observation_frame_budget_seconds + observation_sample_interval_seconds))
observation_timeout=timeout
if command -v gnutimeout >/dev/null 2>&1; then observation_timeout=gnutimeout; fi
if command -v gtimeout >/dev/null 2>&1; then observation_timeout=gtimeout; fi
observation_probe() {
  "$observation_timeout" --kill-after="${observation_probe_kill_grace_seconds}s" "${observation_probe_timeout_seconds}s" "$@" 2>/dev/null
}
observation_unknown() {
  observation_failed=true
  if [[ -d "$observation_state" && ! -L "$observation_state" ]]; then
    if [[ ! -L "$observation_state/incomplete" ]]; then touch "$observation_state/incomplete" 2>/dev/null || true; fi
    # Revoke a previously published verdict even if later collection/storage fails.
    # If replacement cannot be committed, remove only our stale public receipt.
    (
      umask 077
      [[ -d "$observation_state/public" && ! -L "$observation_state/public" ]] || exit 1
      [[ ! -L "$observation_state/public/unknown.pending" &&
        (! -e "$observation_state/public/unknown.pending" || -f "$observation_state/public/unknown.pending") ]] || exit 1
      [[ ! -L "$observation_state/public/report.json" &&
        (! -e "$observation_state/public/report.json" || -f "$observation_state/public/report.json") ]] || exit 1
      printf '{"schema":1,"complete":false}\n' >"$observation_state/public/unknown.pending" || exit 1
      mv "$observation_state/public/unknown.pending" "$observation_state/public/report.json"
    ) 2>/dev/null || {
      if [[ -d "$observation_state/public" && ! -L "$observation_state/public" ]]; then
        rm -f -- "$observation_state/public/report.json" 2>/dev/null || true
      fi
    }
  fi
  echo '::warning::Go component observation is incomplete' >&2
}
observation_bound() {
  local file
  [[ -d "$observation_state" && ! -L "$observation_state" &&
    -d "$observation_state/public" && ! -L "$observation_state/public" &&
    -f "$observation_state/identity.json" && ! -L "$observation_state/identity.json" &&
    -f "$observation_state/paths.json" && ! -L "$observation_state/paths.json" ]] || return 1
  for file in incomplete devices frames.jsonl command.json command.json.pending command-started caches.json caches.json.pending public/report.json public/report.json.pending; do
    [[ ! -L "$observation_state/$file" && (! -e "$observation_state/$file" || -f "$observation_state/$file") ]] || return 1
  done
  [[ "$(wc -c <"$observation_state/identity.json")" -le 8192 && "$(wc -c <"$observation_state/paths.json")" -le 8192 ]] || return 1
  jq -e --arg head "${GITHUB_SHA:-}" --arg source "${GO_DISK_WORKFLOW_SHA:-}" \
    --arg run "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg repository "${GITHUB_REPOSITORY:-}" --arg catalogueRepository "${GO_DISK_WORKFLOW_REPOSITORY:-}" --arg job "${GITHUB_JOB:-}" \
    '.head==$head and .catalogue==$source and .run==$run and .attempt==$attempt and
     .repository==$repository and .catalogueRepository==$catalogueRepository and .job==$job' \
    "$observation_state/identity.json" >/dev/null 2>&1
}
observation_init() {
  [[ ! -e "$observation_state" && ! -L "$observation_state" &&
    "${GITHUB_SHA:-}" =~ ^[a-f0-9]{40}$ && "${GO_DISK_WORKFLOW_SHA:-}" =~ ^[a-f0-9]{40}$ &&
    "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ &&
    "${ImageOS:-unknown}" =~ ^[a-zA-Z0-9._-]{1,64}$ && "${ImageVersion:-unknown}" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || return 1
  (
    umask 077
    mkdir "$observation_state" "$observation_state/public"
  ) || return 1
  local environment checkout module mod_hash sum_hash=null
  environment="$(observation_probe go env -json GOCACHE GOMODCACHE GOROOT GOTMPDIR GOVERSION GOOS GOARCH CGO_ENABLED)" || return 1
  jq -e 'type=="object" and
    ([.GOCACHE,.GOMODCACHE,.GOROOT] | all(type=="string" and startswith("/") and (test("[\\r\\n]")|not))) and
    (.GOTMPDIR|type=="string") and (.GOTMPDIR=="" or (.GOTMPDIR|startswith("/") and (test("[\\r\\n]")|not))) and
    (.GOVERSION|test("^go[0-9]+[.][0-9]+[.][0-9]+$")) and
    ([.GOOS,.GOARCH]|all(test("^[a-z0-9]+$"))) and (.CGO_ENABLED|IN("0","1"))' \
    <<<"$environment" >/dev/null 2>&1 || return 1
  checkout="$(git rev-parse HEAD)" || return 1
  [[ "$checkout" == "$GITHUB_SHA" ]] || return 1
  [[ "${GITHUB_REPOSITORY:-}" =~ ^[a-zA-Z0-9_.-]{1,100}/[a-zA-Z0-9_.-]{1,100}$ &&
    "${GO_DISK_WORKFLOW_REPOSITORY:-}" =~ ^[a-zA-Z0-9_.-]{1,100}/[a-zA-Z0-9_.-]{1,100}$ &&
    "${GITHUB_JOB:-}" =~ ^[a-zA-Z0-9_-]{1,100}$ && "${GITHUB_WORKSPACE:-}" == /* ]] || return 1
  module="$(git rev-parse --show-prefix)" || return 1
  module="${module%/}"
  [[ -n "$module" ]] || module=.
  [[ "$module" =~ ^[a-zA-Z0-9_./-]+$ && "${#module}" -le 256 ]] || return 1
  mod_hash="$(shasum -a 256 go.mod)" || return 1
  mod_hash="${mod_hash%% *}"
  if [[ -f go.sum && ! -L go.sum ]]; then
    sum_hash="$(shasum -a 256 go.sum)" || return 1
    sum_hash="${sum_hash%% *}"
  fi
  [[ "$mod_hash" =~ ^[a-f0-9]{64}$ && ("$sum_hash" == null || "$sum_hash" =~ ^[a-f0-9]{64}$) ]] || return 1
  (
    umask 077
    printf '%s\n' "$environment" >"$observation_state/paths.json"
  ) || return 1
  jq -nc --arg head "$checkout" --arg catalogue "$GO_DISK_WORKFLOW_SHA" --arg run "$GITHUB_RUN_ID" \
    --arg repository "$GITHUB_REPOSITORY" --arg catalogueRepository "$GO_DISK_WORKFLOW_REPOSITORY" --arg job "$GITHUB_JOB" --arg module "$module" \
    --arg attempt "$GITHUB_RUN_ATTEMPT" --arg image "${ImageOS:-unknown}" --arg imageVersion "${ImageVersion:-unknown}" \
    --arg mod "$mod_hash" --arg sum "$sum_hash" --argjson environment "$environment" \
    '{head:$head,catalogue:$catalogue,catalogueRepository:$catalogueRepository,repository:$repository,job:$job,run:$run,attempt:$attempt,image:$image,imageVersion:$imageVersion,
      module:{directory:$module,goModSHA256:$mod,goSumSHA256:(if $sum=="null" then null else $sum end)},
      toolchain:{version:$environment.GOVERSION,os:$environment.GOOS,arch:$environment.GOARCH,cgo:$environment.CGO_ENABLED}}' \
    >"$observation_state/identity.json" || return 1
}
# Collect one fixed label's filesystem counters and optional bounded size walk.
# Failed walks retain an unknown size and numeric diagnostics, without raw output.
observation_entry() {
  local label="$1" path="$2" scope=path status=measured bytes inodes device group size=null component=not-collected frame parent
  local path_source="${3:-fixed-label}" probe_result=not-collected probe_exit=null probe_elapsed=null probe_started
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    parent="$(dirname "$path")"
    while [[ ! -e "$parent" && ! -L "$parent" && "$parent" != / ]]; do parent="$(dirname "$parent")"; done
    [[ -d "$parent" && -x "$parent" ]] || return 1
    path="$parent"
    scope=nearest-existing-parent
    status=absent
    size=0
    component=absent
    probe_result=absent
  fi
  frame="$(observation_probe env LC_ALL=C df -Pk "$path")" || return 1
  bytes="$(awk 'NR==2 && NF==6 {print $2,$3,$4} END {if(NR!=2) exit 1}' <<<"$frame")" || return 1
  frame="$(observation_probe env LC_ALL=C df -Pi "$path")" || return 1
  inodes="$(awk 'NR==2 && NF==6 {print $2,$3,$4} END {if(NR!=2) exit 1}' <<<"$frame")" || return 1
  if ! device="$(observation_probe stat -L -c '%d' -- "$path")"; then
    device="$(observation_probe stat -L -f '%d' "$path")" || return 1
  fi
  [[ "$bytes" =~ ^[0-9]{1,12}\ [0-9]{1,12}\ [0-9]{1,12}$ && "$inodes" =~ ^[0-9]{1,12}\ [0-9]{1,12}\ [0-9]{1,12}$ &&
    "$device" =~ ^[0-9]{1,20}$ ]] || return 1
  touch "$observation_state/devices" || return 1
  group="$(awk -v device="$device" '$0==device {print NR; found=1; exit} END {if(!found) exit 1}' "$observation_state/devices")" || {
    printf '%s\n' "$device" >>"$observation_state/devices" || return 1
    group="$(wc -l <"$observation_state/devices" | tr -d '[:space:]')" || return 1
  }
  if [[ "$status" != absent && "$observation_components" == true && "$label" != root ]]; then
    probe_started=$SECONDS
    if frame="$(observation_probe du -sHk -- "$path")"; then probe_exit=0; else probe_exit=$?; fi
    probe_elapsed=$((SECONDS - probe_started))
    if [[ "$probe_exit" != 0 ]]; then
      probe_result='command-failed'
    elif size="$(awk 'NR==1 {print $1} END {if(NR!=1) exit 1}' <<<"$frame")" && [[ "$size" =~ ^[0-9]{1,12}$ ]]; then
      probe_result=measured
    else
      probe_result=invalid-output
    fi
    if [[ "$probe_result" == measured ]]; then
      component=measured
    else
      size=null
      component=unknown
      observation_unknown
    fi
  fi
  jq -nc --arg label "$label" --arg status "$status" --arg scope "$scope" --arg group "fs-$group" \
    --arg bytes "$bytes" --arg inodes "$inodes" --argjson size "$size" --arg component "$component" \
    --arg source "$path_source" --arg result "$probe_result" --argjson code "$probe_exit" --argjson elapsed "$probe_elapsed" '
    ($bytes|split(" ")|map(tonumber)) as $b | ($inodes|split(" ")|map(tonumber)) as $i |
    if ($b[0]>0 and $b[1]+$b[2]<=$b[0] and $i[0]>0 and $i[1]+$i[2]<=$i[0]) then
      {label:$label,status:$status,filesystemScope:$scope,filesystemGroup:$group,totalKiB:$b[0],usedKiB:$b[1],availableKiB:$b[2],
       totalInodes:$i[0],usedInodes:$i[1],availableInodes:$i[2],componentKiB:$size,componentStatus:$component,pathSource:$source,
       componentProbe:{result:$result,exitCode:$code,elapsedSeconds:$elapsed}}
    else error("inconsistent counters") end'
}
# Append a provenance-bound frame for the eight fixed labels, distinguishing the
# effective Go-temp source from explicit, shared and system-default directories.
observation_frame() {
  observation_bound || return 1
  local environment rows frame index path size temp_source=go-env source
  environment="$(cat "$observation_state/paths.json")" || return 1
  local paths=(/ "$GITHUB_WORKSPACE" "$PWD" "$(jq -r .GOMODCACHE <<<"$environment")" "$(jq -r .GOCACHE <<<"$environment")"
  "$(jq -r .GOROOT <<<"$environment")" "$(jq -r '.GOTMPDIR|select(.!="")' <<<"$environment")" "${RUNNER_TEMP:-/tmp}")
  if [[ -z "${paths[6]}" ]]; then
    paths[6]="${TMPDIR:-/tmp}"
    temp_source=system-default
    [[ -z "${TMPDIR:-}" ]] || temp_source=tmpdir-fallback
  fi
  [[ "${#paths[@]}" == "${#observation_labels[@]}" ]] || return 1
  rows="$(mktemp "$observation_state/rows.XXXXXX")" || return 1
  for index in "${!observation_labels[@]}"; do
    path="${paths[$index]}"
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    source=fixed-label
    [[ "${observation_labels[$index]}" != go-temp ]] || source="$temp_source"
    observation_entry "${observation_labels[$index]}" "$path" "$source" >>"$rows" || return 1
  done
  frame="$(jq -nc --arg phase "$observation_phase" --argjson epoch "$(date +%s)" --slurpfile entries "$rows" \
    '{phase:$phase,epoch:$epoch,entries:$entries}')" || return 1
  printf '%s\n' "$frame" >>"$observation_state/frames.jsonl" || return 1
  size="$(wc -c <"$observation_state/frames.jsonl")" || return 1
  [[ "$size" -le 8388608 ]] || return 1
  rm -f -- "$rows"
}
observation_caches() {
  jq -nc 'def entry($p;$m;$h):
      if ($p|test("^go-[a-zA-Z0-9_./-]{1,500}$")) and ($m=="" or ($m|test("^go-[a-zA-Z0-9_./-]{1,500}$"))) and ($h|IN("true","false",""))
      then {primary:$p,matched:$m,hit:(if $h=="" then null else $h=="true" end)} else error("invalid cache identity") end;
    {module:entry(env.GO_DISK_MODULE_PRIMARY_KEY//"";env.GO_DISK_MODULE_MATCHED_KEY//"";env.GO_DISK_MODULE_CACHE_HIT//""),
     build:entry(env.GO_DISK_BUILD_PRIMARY_KEY//"";env.GO_DISK_BUILD_MATCHED_KEY//"";env.GO_DISK_BUILD_CACHE_HIT//"")}' \
    >"$observation_state/caches.json.pending" 2>/dev/null || return 1
  mv "$observation_state/caches.json.pending" "$observation_state/caches.json"
}
# Validate retained frames and command state before publishing allowlisted fields.
# Unknown measurements or incomplete collection cannot produce a complete report.
observation_publish() {
  observation_bound || return 1
  local complete=true command='{"executed":false,"completed":false,"exit":null,"observerCompleted":false}' caches='{}' identity size
  [[ ! -e "$observation_state/incomplete" && "$observation_failed" == false ]] || complete=false
  identity="$(cat "$observation_state/identity.json")" || return 1
  if [[ -f "$observation_state/frames.jsonl" && ! -L "$observation_state/frames.jsonl" &&
    "$(wc -c <"$observation_state/frames.jsonl")" -le 8388608 ]]; then
    jq -e -s 'type=="array"' "$observation_state/frames.jsonl" >/dev/null 2>&1 || return 1
  else return 1; fi
  if [[ -f "$observation_state/command.json" && ! -L "$observation_state/command.json" ]]; then
    command="$(jq -ce . "$observation_state/command.json" 2>/dev/null)" || return 1
  fi
  if [[ -f "$observation_state/caches.json" && ! -L "$observation_state/caches.json" ]]; then
    caches="$(jq -ce . "$observation_state/caches.json" 2>/dev/null)" || return 1
  else complete=false; fi
  jq -nc --argjson identity "$identity" --slurpfile frames "$observation_state/frames.jsonl" --argjson command "$command" \
    --argjson caches "$caches" --argjson complete "$complete" '
    def number: type=="number" and .>=0 and floor==.;
    def key: type=="string" and test("^go-[a-zA-Z0-9_./-]{1,500}$");
    def cache: (.primary|key) and (.matched=="" or (.matched|key)) and (.hit|IN(true,false,null));
    def probe:
      (if .componentStatus=="unknown" then (.componentProbe.result|IN("command-failed","invalid-output"))
       else .componentProbe.result==.componentStatus end) and
      (.componentProbe | keys==["elapsedSeconds","exitCode","result"] and
        if (.result|IN("absent","not-collected")) then .exitCode==null and .elapsedSeconds==null
        else (.elapsedSeconds|number) and
          if .result=="command-failed" then (.exitCode|number and .>0 and .<=255) else .exitCode==0 end
        end);
    def frame:
      (.phase|IN("after-setup","after-restore","before-command","during-command","command-exit")) and (.epoch|number) and
      ([.entries[].label]|sort)==["build-cache","go-temp","module","module-cache","root","runner-temp","toolchain","workspace"] and
      all(.entries[];
        (.status|IN("measured","absent")) and (.filesystemScope|IN("path","nearest-existing-parent")) and
        (.filesystemGroup|test("^fs-[0-9]{1,3}$")) and (.componentStatus|IN("measured","absent","not-collected","unknown")) and
        (if .label=="go-temp" then (.pathSource|IN("go-env","tmpdir-fallback","system-default")) else .pathSource=="fixed-label" end) and probe and
        ([.totalKiB,.usedKiB,.availableKiB,.totalInodes,.usedInodes,.availableInodes]|all(number)) and
        (.componentKiB==null or (.componentKiB|number)));
    if (($identity.head|test("^[a-f0-9]{40}$")) and ($identity.catalogue|test("^[a-f0-9]{40}$")) and
      ([$identity.repository,$identity.catalogueRepository]|all(test("^[a-zA-Z0-9_.-]{1,100}/[a-zA-Z0-9_.-]{1,100}$"))) and
      ([$identity.run,$identity.attempt]|all(test("^[0-9]{1,30}$"))) and ($identity.job|test("^[a-zA-Z0-9_-]{1,100}$")) and
      ([$identity.image,$identity.imageVersion]|all(test("^[a-zA-Z0-9._-]{1,64}$"))) and
      ($identity.module.directory|test("^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$") and length<=256) and
      ($identity.module.goModSHA256|test("^[a-f0-9]{64}$")) and
      ($identity.module.goSumSHA256==null or ($identity.module.goSumSHA256|test("^[a-f0-9]{64}$"))) and
      ($identity.toolchain.version|test("^go[0-9]+[.][0-9]+[.][0-9]+$")) and
      ([$identity.toolchain.os,$identity.toolchain.arch]|all(test("^[a-z0-9]+$"))) and ($identity.toolchain.cgo|IN("0","1")) and
      ($command.executed|IN(true,false)) and ($command.completed|IN(true,false)) and ($command.observerCompleted|IN(true,false)) and
      ($command.exit==null or ($command.exit|number)) and ($command.finishedEpoch==null or ($command.finishedEpoch|number)) and
      ($caches.module|cache) and ($caches.build|cache) and all($frames[];frame))
    then ($identity|{head,catalogue,catalogueRepository,repository,job,run,attempt,image,imageVersion,
        module:(.module|{directory,goModSHA256,goSumSHA256}),toolchain:(.toolchain|{version,os,arch,cgo})}) +
      {schema:1,command:($command|{executed,completed,exit,finishedEpoch,observerCompleted}),
      caches:($caches|{module:(.module|{primary,matched,hit}),build:(.build|{primary,matched,hit})}),
      frames:[$frames[]|{phase,epoch,entries:[.entries[]|{label,status,filesystemScope,filesystemGroup,totalKiB,usedKiB,availableKiB,totalInodes,usedInodes,availableInodes,componentKiB,componentStatus,pathSource,
        componentProbe:(.componentProbe|{result,exitCode,elapsedSeconds})}]}],
      quotaLimits:"not-established",cacheArchiveIdentity:"not-established",
      complete:($complete and $command.completed==true and $command.observerCompleted==true and
        $identity.image!="unknown" and $identity.imageVersion!="unknown" and
        all($frames[].entries[];.componentStatus!="unknown") and
        all(["after-setup","after-restore","before-command","during-command","command-exit"][]; . as $phase|any($frames[];.phase==$phase))),
      limitations:["Samples are not instantaneous peaks.","Component walks can delay samples.","Nearest-parent counters do not establish absent-path quotas."]}
    else error("invalid observation") end' \
    >"$observation_state/public/report.json.pending" || return 1
  size="$(wc -c <"$observation_state/public/report.json.pending")" || return 1
  [[ "$size" -le 8388608 ]] || return 1
  mv "$observation_state/public/report.json.pending" "$observation_state/public/report.json"
}
if [[ "${1:-}" == snapshot || "${1:-}" == publish ]]; then
  if [[ "$observation" != true ]]; then exit 0; fi
  umask 077
  if [[ "$1" == publish ]]; then
    observation_publish 2>/dev/null || observation_unknown
  else
    case "${2:-}" in
    after-setup) observation_init 2>/dev/null || observation_unknown ;;
    after-restore) if ! observation_bound || ! observation_caches 2>/dev/null; then observation_unknown; fi ;;
    *)
      echo 'Invalid Go observation phase' >&2
      exit 2
      ;;
    esac
    observation_phase="$2"
    observation_frame 2>/dev/null || observation_unknown
  fi
  exit 0
fi
phase="${1:-}"
case "$phase" in build | test | coverage | cleanup-build | cleanup-test | cleanup-coverage) shift ;; *)
  echo 'Invalid Go disk measurement phase' >&2
  exit 2
  ;;
esac
[[ "$#" -gt 0 ]] || {
  echo 'Missing measured command' >&2
  exit 2
}
measurement_unknown=false
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/go-disk.XXXXXX")" || {
  scratch=''
  measurement_unknown=true
}
monitor_pid=''
observation_pid=''
command_pid=''
# Separate process groups let cancellation stop the command's children as well.
set -m
stop_group() {
  local pid="$1"
  if [[ -n "$pid" ]]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 -- "-$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 -- "-$pid" 2>/dev/null; then
      measurement_unknown=true
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || measurement_unknown=true
  fi
}
stop_monitor() {
  local stop_tick
  if [[ "$observation" == true && -n "$monitor_pid" && "${cancelling:-false}" != true ]]; then
    touch "$scratch/stop-requested" || measurement_unknown=true
    for ((stop_tick = 0; stop_tick < observation_stop_budget_seconds * 10; stop_tick++)); do
      kill -0 "$monitor_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$monitor_pid" 2>/dev/null; then
      measurement_unknown=true
      stop_group "$monitor_pid"
    else
      wait "$monitor_pid" 2>/dev/null || measurement_unknown=true
    fi
    if [[ ! -f "$scratch/stop-acknowledged" ]] || [[ "$(cat "$scratch/stop-acknowledged")" != false ]]; then measurement_unknown=true; fi
  else stop_group "$monitor_pid"; fi
  monitor_pid=''
}
trap 'stop_monitor; stop_group "$observation_pid"; if [[ -n "$scratch" ]]; then rm -rf -- "$scratch" || true; fi' EXIT
# Bash invokes this handler from the INT/TERM traps below.
# shellcheck disable=SC2329
cancel() {
  cancelling=true
  trap '' INT TERM
  if [[ -n "$command_pid" ]]; then
    kill -TERM -- "-$command_pid" 2>/dev/null || true
    # A command may ignore TERM; never wait indefinitely during cancellation.
    for _ in {1..20}; do
      kill -0 -- "-$command_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true
  fi
  exit "$1"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
sample() {
  local frame values total used available
  # Capture the complete command before parsing: plausible stdout followed by
  # an operational failure is unknown, never an accepted partial observation.
  if [[ "$observation" == true ]]; then
    frame="$(observation_probe env LC_ALL=C df -Pk .)" || return 1
  else
    frame="$(LC_ALL=C df -Pk . 2>/dev/null)" || return 1
  fi
  if ! values="$(awk 'NR == 2 {print $2, $3, $4} END {if (NR != 2) exit 1}' <<<"$frame")"; then
    return 1
  fi
  if [[ ! "$values" =~ ^([0-9]{1,12})[[:space:]]([0-9]{1,12})[[:space:]]([0-9]{1,12})$ ]]; then
    return 1
  fi
  total=$((10#${BASH_REMATCH[1]}))
  used=$((10#${BASH_REMATCH[2]}))
  available=$((10#${BASH_REMATCH[3]}))
  if ((total == 0 || used > total || available > total || used + available > total)); then
    return 1
  fi
  printf '%s %s\n' "$used" "$available" >>"$scratch/samples" || return 1
  if [[ "$observation" == true ]]; then
    observation_frame || {
      observation_unknown
      return 1
    }
  fi
}
collect_sample() {
  # Initial/final reads also need their own bounded, cancellable group.
  local ticks=20
  # Rich frames share the same derived bound as cooperative sampler shutdown.
  # A legacy single-df sample retains its original two-second outer bound.
  if [[ "$observation" == true ]]; then ticks=$((observation_frame_budget_seconds * 10)); fi
  (
    set +m
    sample && [[ "$observation_failed" == false ]]
  ) 2>/dev/null &
  observation_pid=$!
  for ((wait_tick = 0; wait_tick < ticks; wait_tick++)); do
    kill -0 "$observation_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$observation_pid" 2>/dev/null; then
    measurement_unknown=true
    stop_group "$observation_pid"
  else
    wait "$observation_pid" 2>/dev/null || measurement_unknown=true
  fi
  observation_pid=''
}
if [[ "$observation" == true ]]; then
  if ! observation_bound || [[ -e "$observation_state/command-started" ]]; then
    observation_unknown
  elif ! (
    umask 077
    set -C
    : >"$observation_state/command-started"
  ) 2>/dev/null; then observation_unknown; fi
fi
if [[ -n "$scratch" ]]; then
  collect_sample
  (
    # All sampler descendants must stay in the sampler's process group.
    set +m
    if [[ "$observation" == true ]]; then
      trap 'exit 130' INT
      trap 'exit 143' TERM
      observation_phase=during-command
      for ((tick = 0; tick < 1800; tick++)); do
        if [[ -f "$scratch/stop-requested" ]]; then
          printf '%s\n' "$observation_failed" >"$scratch/stop-acknowledged" || exit 1
          exit 0
        fi
        sleep "$observation_sample_interval_seconds" || exit 1
        if [[ -f "$scratch/stop-requested" ]]; then
          printf '%s\n' "$observation_failed" >"$scratch/stop-acknowledged" || exit 1
          exit 0
        fi
        observation_components=false
        if ((tick % 60 == 0)); then observation_components=true; fi
        sample || exit 1
      done
      exit 1
    else
      trap 'exit 0' INT TERM
      while sleep 1; do sample || exit 1; done
    fi
  ) 2>/dev/null &
  monitor_pid=$!
fi
"$@" &
command_pid=$!
rc=0
wait "$command_pid" || rc=$?
command_pid=''
if [[ "$observation" == true ]]; then
  if ! observation_bound || ! (
    umask 077
    jq -nc --argjson rc "$rc" --argjson finished "$(date +%s)" \
      '{executed:true,completed:true,exit:$rc,finishedEpoch:$finished,observerCompleted:false}' >"$observation_state/command.json.pending" &&
      mv "$observation_state/command.json.pending" "$observation_state/command.json"
  ) 2>/dev/null; then observation_unknown; fi
fi
# A sampler that stopped by itself cannot establish complete observations.
if [[ -n "$monitor_pid" ]]; then
  kill -0 "$monitor_pid" 2>/dev/null || measurement_unknown=true
fi
stop_monitor
observation_phase='command-exit'
observation_components=true
if [[ -n "$scratch" ]]; then collect_sample; fi
if [[ "$observation" == true ]]; then
  # Persist sampler/edge completion separately from Go completion. A later
  # publisher must not turn a lost failure marker into a successful verdict.
  observer_completed=false
  if [[ "$measurement_unknown" == false && "$observation_failed" == false ]]; then observer_completed=true; fi
  if ! observation_bound || ! (
    umask 077
    jq --argjson observerCompleted "$observer_completed" '.observerCompleted=$observerCompleted' \
      "$observation_state/command.json" >"$observation_state/command.json.pending" &&
      mv "$observation_state/command.json.pending" "$observation_state/command.json"
  ) 2>/dev/null; then observation_unknown; fi
  if [[ "$measurement_unknown" == true ]]; then observation_unknown; fi
  observation_publish 2>/dev/null || observation_unknown
fi
samples=0
initial=null
final=null
minimum=null
maximum=null
if [[ -n "$scratch" && -f "$scratch/samples" ]]; then
  while read -r used available; do
    ((samples += 1))
    [[ "$initial" != null ]] || initial="$available"
    final="$available"
    if [[ "$minimum" == null ]] || ((available < minimum)); then minimum="$available"; fi
    if [[ "$maximum" == null ]] || ((used > maximum)); then maximum="$used"; fi
  done <"$scratch/samples" || measurement_unknown=true
fi
status=measured
if [[ "$measurement_unknown" == true ]] || ((samples < 2)); then
  status=unknown
  initial=null
  final=null
  minimum=null
  maximum=null
fi
receipt="$(jq -cn --arg status "$status" --arg phase "$phase" \
  --arg run_id "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg head "${GITHUB_SHA:-}" --arg workflow_sha "${GO_DISK_WORKFLOW_SHA:-${GITHUB_WORKFLOW_SHA:-}}" --arg job "${GITHUB_JOB:-}" \
  --argjson samples "$samples" --argjson initial "$initial" --argjson final "$final" \
  --argjson minimum "$minimum" --argjson maximum "$maximum" --argjson rc "$rc" \
  '{status:$status,phase:$phase,run_id:$run_id,attempt:$attempt,head:$head,workflow_sha:$workflow_sha,job:$job,interval_seconds:1,samples:$samples,initial_available_kib:$initial,final_available_kib:$final,minimum_available_kib:$minimum,maximum_used_kib:$maximum,command_exit:$rc}')" || {
  echo '::warning::Go disk measurement UNKNOWN: receipt could not be encoded' >&2
  exit "$rc"
}
printf 'GO_DISK_USAGE %s\n' "$receipt" || true
if [[ -n "${GO_DISK_RECEIPT_FILE:-}" ]]; then
  if ! (
    umask 077
    printf '%s\n' "$receipt" >"$GO_DISK_RECEIPT_FILE"
  ); then
    echo '::warning::Go disk receipt could not be retained; native collection is incomplete' >&2
  fi
fi
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Go disk usage: %s\n\nSampled filesystem headroom (1-second interval; not an exact peak).\n\n' "$phase"
    printf '%s\n' '```json' "$receipt" '```'
  } >>"$GITHUB_STEP_SUMMARY" || true
fi
exit "$rc"
