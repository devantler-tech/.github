#!/usr/bin/env bash
# version-pin-census.sh [ROOT] — list every version pin the catalogue runs (#627).
#
# Scope: workflows, workflow templates, action metadata and Go modules. Each pin is one of:
#   tracked   Dependabot updates it: a full-SHA action reference with a version
#             comment in a directory Dependabot's github-actions entry covers, or
#             a module with dependencies in a gomod entry that does not ignore "*".
#   manifest  .github/version-pins.json lists it with its refresh path.
#   violation neither, or mutable: an action ref that is not a full SHA, or an
#             image without a digest (any branch of an image expression).
# Limits (actions/CONTRIBUTING.md): no shell-variable resolution beyond *_IMAGE
# assignments, tool versions need a dotted number, a quoted "#" ends the scan.
# Prints one TSV row per pin (status, kind, file:line, pin). Exits 0 when every pin
# is tracked or listed and every manifest entry still matches a pin, 1 on any
# violation or stale entry, and 2 when an input cannot be read. Never reads the
# network: images inside third-party actions are outside what it can see.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$root"
manifest=.github/version-pins.json
dependabot=.github/dependabot.yml
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
unreadable() { echo "::error::version-pin census: $*" >&2; exit 2; }

[[ -f "$manifest" && -f "$dependabot" ]] || unreadable 'the manifest or dependabot.yml is missing'
jq -e '
  .schema == 1 and (.pins | type == "array") and
  all(.pins[];
    (keys | sort) == ["files", "kind", "pin", "refresh"] and
    (.kind | IN("action", "image", "tool", "module")) and
    (.pin | type == "string" and length > 0) and
    (.files | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.refresh | type == "string" and length >= 20))
' "$manifest" >/dev/null 2>&1 || unreadable "$manifest does not match its schema"
yq -o=json '.updates' "$dependabot" > "$scratch/updates.json" 2>/dev/null || unreadable "$dependabot is unreadable"
# An entry that ignores every dependency or may open no pull request updates nothing.
updating='select(([.ignore[]?."dependency-name"] | index("*") | not) and ((."open-pull-requests-limit" // 5) > 0))'
jq -r "[.[] | select(.\"package-ecosystem\" == \"github-actions\") | $updating | (.directories // [.directory])[]] | .[]" \
  "$scratch/updates.json" > "$scratch/action-dirs" || unreadable 'github-actions directories are unreadable'
jq -r "[.[] | select(.\"package-ecosystem\" == \"gomod\") | $updating | (.directories // [.directory])[]] | .[]" \
  "$scratch/updates.json" > "$scratch/gomod-dirs" || unreadable 'gomod directories are unreadable'
jq -r '.pins[] | .kind as $k | .pin as $p | .files[] | [$k, ., $p] | @tsv' "$manifest" > "$scratch/listed"

# Dependabot's github-actions updater reads .github/workflows for "/" and action
# metadata in each listed directory ("*" matches exactly one path segment).
actions_tracked() {
  local file="$1" dir pattern regex
  case "$file" in
    .github/workflows/*) dir=/ ;;
    *) dir="/$(dirname "$file")" ;;
  esac
  while IFS= read -r pattern; do
    regex="${pattern//./\\.}"
    regex="^${regex//\*/[^/]+}$"
    [[ "$dir" =~ $regex ]] && return 0
  done < "$scratch/action-dirs"
  return 1
}

: > "$scratch/found"
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$scratch/found"; }
listed() { grep -qxF "$(printf '%s\t%s\t%s' "$1" "$2" "$3")" "$scratch/listed"; }
classify() { # kind file line pin [tracked]
  if [[ "${5:-}" == tracked ]]; then emit tracked "$1" "$2:$3" "$4"
  elif listed "$1" "$2" "$4"; then emit manifest "$1" "$2:$3" "$4"
  else emit violation "$1" "$2:$3" "$4"; fi
}

[[ -d .github/workflows ]] || unreadable '.github/workflows is missing'
action_roots=()
for dir in actions .github/actions .github/fixtures; do [[ ! -d "$dir" ]] || action_roots+=("$dir"); done
workflow_roots=(.github/workflows)
# Organization workflow templates are copied into consumers with their pins.
[[ ! -d workflow-templates ]] || workflow_roots+=(workflow-templates)
find "${workflow_roots[@]}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) > "$scratch/files.raw"
((${#action_roots[@]} == 0)) || find "${action_roots[@]}" -type f \( -name action.yml -o -name action.yaml \) >> "$scratch/files.raw"
sed 's#^\./##' "$scratch/files.raw" | LC_ALL=C sort > "$scratch/files"
[[ -s "$scratch/files" ]] || unreadable 'no workflow or action files found'

digest_re='[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}'
# shellcheck disable=SC2016 # The literal marker of a workflow expression.
expression_marker='${{'
# One awk pass per file extracts candidate records; bash classifies the few hundred records.
# Records: U line ref comment (action uses), I line value (image/container), T line token (tool).
# shellcheck disable=SC2016 # The awk program is single-quoted on purpose.
extract='
  /^[[:space:]]*(#|$)/ {next}
  {
    match($0, /^[[:space:]]*/); indent = RLENGTH
    # A block-scalar version input (dotnet-version: |) lists one version per deeper line.
    if (blockkey != "" && indent > blockindent) {
      value = $0; sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+#.*$/, "", value)
      if (value != "") printf "T\t%d\t%s: %s\n", NR, blockkey, value
      next
    }
    blockkey = ""
    code = $0; comment = ""
    if (match(code, /[[:space:]]#/)) {comment = substr(code, RSTART + 2); code = substr(code, 1, RSTART - 1)}
    if (match(code, /^[[:space:]]*(-[[:space:]]+)?[A-Za-z0-9_-]*(version|release|VERSION)[A-Za-z0-9_-]*:[[:space:]]*[|>][-+0-9]*[[:space:]]*$/)) {
      blockkey = code; sub(/^[[:space:]]*(-[[:space:]]+)?/, "", blockkey); sub(/:.*$/, "", blockkey)
      blockindent = indent; next
    }
    if (match(code, /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/)) {
      ref = substr(code, RSTART + RLENGTH); gsub(/["\047]/, "", ref); sub(/[[:space:]].*$/, "", ref)
      printf "U\t%d\t%s\t%s\n", NR, ref, comment; next
    }
    if (match(code, /^[[:space:]]*(-[[:space:]]+)?(image|container):[[:space:]]*[^[:space:]]/)) {
      value = code; sub(/^[[:space:]]*(-[[:space:]]+)?(image|container):[[:space:]]*/, "", value)
      printf "I\t%d\t%s\n", NR, value; next
    }
    # Any other image digest (an env value, a JSON string) is a pin as well.
    rest = code
    while (match(rest, /[a-z0-9][a-z0-9._\/-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]+/)) {
      printf "D\t%d\t%s\n", NR, substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    }
    # An *_IMAGE assignment names an image that later steps pull or run.
    if (match(code, /^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?[A-Z][A-Z0-9_]*_IMAGE(:[[:space:]]|=)[[:space:]]*[^[:space:]]/)) {
      value = substr(code, RSTART); sub(/^[[:space:]]*(-[[:space:]]+)?(export[[:space:]]+)?[A-Z0-9_]*_IMAGE[=:][[:space:]]*/, "", value); sub(/[[:space:]].*$/, "", value)
      gsub(/["\047]/, "", value); printf "K\t%d\t%s\n", NR, value
    }
    # docker run/pull/create: the first argument after the options is the image.
    # Continued shell lines are joined so an image on a later line is still seen.
    joined = pending code; pending = ""
    if (joined ~ /\\[[:space:]]*$/) {sub(/\\[[:space:]]*$/, " ", joined); pending = joined}
    else {
      n = split(joined, w, /[[:space:]]+/)
      for (i = 1; i < n; i++) if (w[i] == "docker" && (w[i + 1] == "run" || w[i + 1] == "pull" || w[i + 1] == "create")) {
        j = i + 2
        while (j <= n && (w[j] == "" || w[j] ~ /^-/)) {
          if (w[j] !~ /=/ && w[j] ~ /^(-[evwuplhm]|--(env|env-file|volume|workdir|name|network|pull|user|entrypoint|publish|platform|mount|label|cidfile|add-host|hostname|memory|cpus|shm-size|tmpfs|ulimit|device|security-opt|cap-add|cap-drop|log-driver|log-opt|restart|stop-signal|group-add))$/) j++
          j++
        }
        if (j <= n) {t = w[j]; gsub(/["\047]/, "", t); printf "R\t%d\t%s\n", NR, t}
      }
    }
    rest = code
    while (match(rest, /[A-Za-z0-9._\/@-]*[A-Za-z0-9]@v?[0-9]+(\.[0-9]+)+|[A-Za-z0-9_-]*(version|release):[[:space:]]*["\047]?v?[0-9][A-Za-z0-9._-]*|[A-Z][A-Z0-9_]*_VERSION[=:][[:space:]]*["\047]?v?[0-9][A-Za-z0-9._-]*/)) {
      token = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
      gsub(/["\047]/, "", token); sub(/:[[:space:]]+/, ": ", token)
      printf "T\t%d\t%s\n", NR, token
    }
  }'
while IFS= read -r file; do
  [[ -r "$file" ]] || unreadable "$file is unreadable"
  awk "$extract" "$file" > "$scratch/records" || unreadable "$file could not be scanned"
  while IFS=$'\t' read -r type line value comment; do
    case "$type" in
      U)
        case "$value" in
          ./* | \$/*) ;;
          docker://*)
            image="${value#docker://}"
            if [[ "$image" =~ ^${digest_re}$ ]]; then classify image "$file" "$line" "$image"
            else emit violation image "$file:$line" "$image (mutable: no digest)"; fi ;;
          *@*)
            if [[ ! "${value##*@}" =~ ^[0-9a-f]{40}$ ]]; then
              emit violation action "$file:$line" "$value (mutable: not a full SHA)"
            elif actions_tracked "$file" && [[ "$comment" =~ ^[[:space:]]*v?[0-9]+(\.[0-9]+)* ]]; then
              classify action "$file" "$line" "$value" tracked
            else
              classify action "$file" "$line" "$value"
            fi ;;
          *) emit violation action "$file:$line" "$value (mutable: no ref)" ;;
        esac ;;
      I)
        if [[ "$value" == *"$expression_marker"* ]]; then
          # Every branch of an expression must be a digest-pinned literal or empty.
          # Only result branches count: a literal after ${{, && or ||, not a comparison operand.
          literals="$(grep -oE "(\\$\\{\\{|&&|\\|\\|)[[:space:]]*'[^']*'" <<< "$value" | grep -oE "'[^']*'" || true)"
          if [[ -z "$literals" ]]; then
            emit violation image "$file:$line" "$value (unverifiable expression)"
            continue
          fi
          while IFS= read -r literal; do
            literal="${literal#\'}"; literal="${literal%\'}"
            if [[ -z "$literal" ]]; then continue
            elif [[ "$literal" =~ ^${digest_re}$ ]]; then classify image "$file" "$line" "$literal"
            else emit violation image "$file:$line" "$literal (mutable: no digest)"; fi
          done <<< "$literals"
        elif [[ "$value" =~ ^[\"\']?(${digest_re})[\"\']?$ ]]; then
          classify image "$file" "$line" "${BASH_REMATCH[1]}"
        elif [[ "$value" != Dockerfile ]]; then
          emit violation image "$file:$line" "$value (mutable: no digest)"
        fi ;;
      D)
        if [[ "$value" =~ ^${digest_re}$ ]]; then classify image "$file" "$line" "$value"
        else emit violation image "$file:$line" "$value (malformed digest)"; fi ;;
      K | R)
        # A variable reference is checked where the variable is assigned.
        if [[ "$value" == *\$* || "$value" =~ ^${digest_re}$ ]]; then :
        else emit violation image "$file:$line" "$value (mutable: no digest)"; fi ;;
      T) classify tool "$file" "$line" "$value" ;;
    esac
  done < "$scratch/records"
done < "$scratch/files"

find . -name go.mod -not -path './.git/*' > "$scratch/gomods.raw"
LC_ALL=C sort "$scratch/gomods.raw" > "$scratch/gomods"
# A module that requires other modules must receive updates or be listed (frozen).
# Requirements replaced by a local path are part of this repository, not versions.
while IFS= read -r gomod; do
  gomod="${gomod#./}"
  requirements="$(awk '
    $1 == "replace" && $NF ~ /^\.\.?\// {local[$2] = 1}
    /^require[[:space:]]*\(/ {block = 1; next}
    block && /^\)/ {block = 0; next}
    block && NF && $1 !~ /^\/\// {required[$1] = 1}
    /^require[[:space:]]+[^(]/ {required[$2] = 1}
    END {for (m in required) if (!(m in local)) count++; print count + 0}' "$gomod")" || unreadable "$gomod is unreadable"
  ((requirements > 0)) || continue
  module="$(awk '$1 == "module" {print $2; exit}' "$gomod")"
  [[ -n "$module" ]] || unreadable "$gomod declares no module"
  if grep -qxF "/$(dirname "$gomod")" "$scratch/gomod-dirs"; then
    classify module "$gomod" 1 "$module" tracked
  else
    classify module "$gomod" 1 "$module"
  fi
done < "$scratch/gomods"

cat "$scratch/found"
status=0
if grep -q '^violation' "$scratch/found"; then
  echo "::error::version-pin census: a pin is mutable, or neither tracked by Dependabot nor listed in $manifest" >&2
  status=1
fi
# Every listed pin must still exist, so the manifest never outlives what it describes.
while IFS=$'\t' read -r kind file pin; do
  if ! awk -F'\t' -v k="$kind" -v f="$file" -v p="$pin" '
      $1 == "manifest" && $2 == k && $4 == p && index($3, f ":") == 1 && substr($3, length(f) + 2) ~ /^[0-9]+$/ {found = 1}
      END {exit !found}' "$scratch/found"; then
    echo "::error::version-pin census: stale manifest entry $kind $pin in $file" >&2
    status=1
  fi
done < "$scratch/listed"
exit "$status"
