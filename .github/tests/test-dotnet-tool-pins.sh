#!/usr/bin/env bash

# Pins how the reusable workflows and composite actions install .NET tools (#265).
#
#   1. Every line that installs or updates a .NET tool has exactly one allowed shape:
#
#        dotnet tool install --global <tool> --version <exact version>
#
#      on a line of its own, with nothing before or after it. An unpinned install takes
#      whatever upstream released last, and publish-dotnet-library.yaml runs dotnet-releaser
#      with the NuGet API key and a write-capable token.
#   2. dotnet-releaser in particular stays pinned, so removing its install line cannot make
#      this check pass vacuously.
#
# The check is an allow-list, not a shell parser. Chained commands, trailing comments,
# quoting, escapes and line continuations each gave an earlier parser a way to miss an
# unpinned install; here any of them simply fails, and the fix is to put the install on its
# own line in the shape above.
#
# The pins are bumped by hand after reviewing the upstream release. A Dependabot-tracked tool
# manifest is deliberately not used: adding one turns on GitHub's automatic NuGet dependency
# submission, which restores the deliberately broken .github/fixtures projects and fails.

set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

allowed='^[[:space:]]*dotnet tool install --global ([A-Za-z0-9._-]+) --version [0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?[[:space:]]*$'
# YAML is never parsed here by hand. Every `run:` value in a workflow or action is read with
# yq, which applies YAML's own folding, chomping and indentation-indicator rules, so the text
# checked is exactly the script the runner executes. Hand-rolled folding kept missing header
# spellings (>, >-, >2-, a trailing comment, an explicit indentation indicator); a parser has
# no spellings to miss. A file yq cannot parse fails the check rather than being skipped.
command -v yq >/dev/null 2>&1 || fail "yq is required to read workflow and action run: scripts"
command -v jq >/dev/null 2>&1 || fail "jq is required to read workflow and action run: scripts"

# scan_installs: reads shell text and prints <label>:<line>:<command> for every command that
# mentions a .NET tool install or update. Lines continued with a trailing backslash are joined
# first, so a split command cannot bypass detection; whole-line comments are ignored, and a
# pending continuation is flushed before a comment, a new file or the end of input.
scan_installs() {
  awk -v label="${SCAN_LABEL:-}" -v offset="${SCAN_OFFSET:-0}" '
    function where() { return (label != "" ? label : (FILENAME && FILENAME != "-" ? FILENAME : "stdin")) }

    function norm(s,   t) {
      t = s
      gsub(/\\/, "", t)
      gsub(/["'\'']/, "", t)
      return t
    }

    function is_tool_cmd(s,   t) {
      t = norm(s)
      return (t ~ /tool[[:space:]]+(install|update)([[:space:]]|$)/ || (t ~ /dotnet[[:space:]]+tool/ && t !~ /dotnet[[:space:]]+tool[[:space:]]+(list|run|restore|search)([[:space:]]|$)/))
    }

    function flush_buf() {
      if (buf != "") {
        if (is_tool_cmd(buf)) {
          print where() ":" (start_line + offset) ":" buf
        }
        buf = ""
        start_line = 0
      }
      glue = 0
    }

    FNR == 1 { flush_buf() }
    /^[[:space:]]*#/ {
      flush_buf()
      next
    }

    # A backslash directly after a character continues the same token (dot\ + net is
    # dotnet), so the next line is glued on without its indentation; a backslash after
    # whitespace separates tokens and is joined with a space.
    /[[:space:]]*\\[[:space:]]*$/ {
      piece = $0
      spans = (piece ~ /[^[:space:]]\\[[:space:]]*$/)
      sub(/[[:space:]]*\\[[:space:]]*$/, "", piece)
      if (glue) { sub(/^[[:space:]]+/, "", piece) }
      if (buf == "") { start_line = FNR }
      buf = buf piece (spans ? "" : " ")
      glue = spans
      next
    }
    {
      if (buf != "") {
        piece = $0
        if (glue) { sub(/^[[:space:]]+/, "", piece) }
        glue = 0
        line = buf piece
        buf = ""
        fnr = start_line
        start_line = 0
      } else {
        line = $0
        fnr = FNR
      }
      if (is_tool_cmd(line)) {
        print where() ":" (fnr + offset) ":" line
      }
    }
    END {
      flush_buf()
    }
  ' "$@"
}

# scan_yaml <file>: scans every run: value in a workflow or action file, reporting each hit at
# the run: key's line plus its line inside the script. Returns non-zero when yq cannot parse
# the file, so an unreadable file can never read as one with no installs.
scan_yaml() {
  local file="$1" runs line encoded
  runs="$(yq -o=json '[explode(.) | .. | select(tag == "!!map") | select(has("run")) | .run | select(tag == "!!str") | {"line": line, "run": .}]' "$file")" ||
    return 1
  while IFS=$'\t' read -r line encoded; do
    [[ -n "$line" ]] || continue
    printf '%s' "$encoded" | base64 --decode | SCAN_LABEL="$file" SCAN_OFFSET="$line" scan_installs
  done < <(printf '%s' "$runs" | jq -r '.[] | [(.line | tostring), (.run | @base64)] | @tsv')
}

# scan_file <file>: YAML goes through the parser, shell scripts are scanned as they are.
scan_file() {
  case "$1" in
    *.yaml | *.yml) scan_yaml "$1" ;;
    *) scan_installs "$1" ;;
  esac
}

search_roots=()
for dir in .github/workflows .github/actions .github/scripts actions .scripts scripts; do
  [[ -d "$dir" ]] && search_roots+=("$dir")
done

target_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && target_files+=("$f")
done < <(find "${search_roots[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \) 2>/dev/null | sort)

[[ ${#target_files[@]} -gt 0 ]] || fail "found no workflow, action or script files to scan"

# Every command that mentions installing or updating a .NET tool, except whole-line comments.
installs=""
for f in "${target_files[@]}"; do
  found="$(scan_file "$f")" || fail "$f could not be parsed as YAML — refusing to skip it"
  [[ -n "$found" ]] && installs+="${installs:+$'\n'}$found"
done
[[ -n "$installs" ]] || fail "found no 'dotnet tool install' lines — refusing to pass vacuously"
# does not pin dotnet-releaser.
check() {
  local line where command releaser_pinned=false
  while IFS= read -r line; do
    where="${line%%:*}:$(printf '%s' "$line" | cut -d: -f2)"
    command="${line#*:*:}"
    [[ "$command" =~ $allowed ]] ||
      fail "$where must be exactly 'dotnet tool install --global <tool> --version <x.y.z>' on its own line: ${command#"${command%%[![:space:]]*}"}"
    if [[ "$where" == .github/workflows/publish-dotnet-library.yaml:* && "${BASH_REMATCH[1]}" == dotnet-releaser ]]; then
      releaser_pinned=true
    fi
  done <<<"$1"
  "$releaser_pinned" || fail "publish-dotnet-library.yaml does not install dotnet-releaser at an exact --version"
}

# Negative controls: shapes that earlier versions of this check let through, each placed on
# a line after a correctly pinned releaser install so only the shape itself can fail it.
pinned='.github/workflows/publish-dotnet-library.yaml:1:          dotnet tool install --global dotnet-releaser --version 0.24.0'
(check "$pinned") || fail "positive control failed: a correctly pinned install was rejected"
while IFS= read -r bad; do
  if (check "$pinned
.github/workflows/publish-dotnet-library.yaml:2:$bad") 2>/dev/null; then
    fail "negative control passed: $bad"
  fi
done <<'EOF'
          dotnet tool install --global dotnet-releaser
          dotnet tool install --global dotnet-releaser; dotnet tool install --global reportgenerator --version 5.5.10
          dotnet tool install --global dotnet-releaser # --version 0.24.0
          dotnet tool install --global dotnet-releaser;# --version 0.24.0
          echo " # note"; dotnet tool install --global reportgenerator
          echo "a \" # b"; dotnet tool install --global dotnet-releaser
          dotnet tool install --global dotnet-releaser --version 0.24.0 \
          dotnet tool update --global dotnet-releaser
          dotnet  tool  install --global dotnet-releaser --version latest
EOF

# Negative control: an unpinned install split across lines with a backslash must reach
# the pin check and be rejected.
continued_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  "          dotnet tool \\" \
  '            install --global dotnet-releaser' | scan_installs)"
if (check "$continued_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install split across lines was not rejected"
fi

# Negative control: an unpinned install continued with a backslash before an EOF comment
# must be flushed and rejected.
eof_comment_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  "          dotnet tool install --global evil-tool \\" \
  '          # end of file comment' | scan_installs)"
if (check "$eof_comment_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install before EOF comment was not rejected"
fi

# Negative control: an unpinned install continued with a backslash at raw EOF must be flushed
# and rejected.
raw_eof_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  "          dotnet tool install --global evil-tool \\" | scan_installs)"
if (check "$raw_eof_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install at raw EOF was not rejected"
fi

# Negative controls: unpinned installs folded across lines by YAML itself must be read the way
# YAML reads them — a plain folded header, one with a chomping indicator and a comment, and one
# with an explicit indentation indicator whose body sits a single space deeper.
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

printf '%s\n' \
  'jobs:' \
  '  publish:' \
  '    steps:' \
  '      - name: Publish' \
  '        run: |' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' >"$fixture_dir/pinned.yaml"
pinned_yaml_scan="$(scan_yaml "$fixture_dir/pinned.yaml")" || fail "positive control failed: pinned fixture did not parse"
[[ -n "$pinned_yaml_scan" ]] || fail "positive control failed: a pinned install in a run: block was not found"
(check "${pinned_yaml_scan//$fixture_dir\/pinned.yaml/.github/workflows/publish-dotnet-library.yaml}") ||
  fail "positive control failed: a pinned install in a run: block was rejected"

for header in '>' '>- # explanation' '>1'; do
  body_indent='          '
  [[ "$header" == '>1' ]] && body_indent='         '
  printf '%s\n' \
    'jobs:' \
    '  publish:' \
    '    steps:' \
    '      - name: Publish' \
    "        run: $header" \
    "${body_indent}dotnet" \
    "${body_indent}tool" \
    "${body_indent}install --global evil-tool" >"$fixture_dir/folded.yaml"
  folded_scan="$(scan_yaml "$fixture_dir/folded.yaml")" || fail "folded fixture ($header) did not parse"
  # An empty scan would let the check below fail on a blank line and look like a rejection.
  [[ "$folded_scan" == *evil-tool* ]] || fail "negative control found no install folded under 'run: $header'"
  if (check "$pinned
$folded_scan") 2>/dev/null; then
    fail "negative control passed: unpinned install folded under 'run: $header' was not rejected"
  fi
done

# Negative control: a run: key with quotes ('run': >) must be parsed by YAML and rejected when unpinned.
printf '%s\n' \
  'jobs:' \
  '  publish:' \
  '    steps:' \
  '      - name: Publish' \
  "        'run': >" \
  '          dotnet tool install --global evil-tool' >"$fixture_dir/quoted_run.yaml"
quoted_run_scan="$(scan_yaml "$fixture_dir/quoted_run.yaml")" || fail "quoted run fixture did not parse"
[[ "$quoted_run_scan" == *evil-tool* ]] || fail "negative control found no install under \"'run': >\""
if (check "$pinned
$quoted_run_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install under \"'run': >\" was not rejected"
fi

# Negative control: a file yq cannot parse must fail the scan, never read as empty.
printf '%s\n' 'jobs: [unclosed' >"$fixture_dir/broken.yaml"
if scan_yaml "$fixture_dir/broken.yaml" >/dev/null 2>&1; then
  fail "negative control passed: an unparseable YAML file was scanned as if it had no installs"
fi

# Negative control: an unpinned command where 'dotnet tool' is split on its own line
# must be caught and rejected.
split_keyword_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  '          dotnet tool' \
  '          install --global evil-tool' | scan_installs)"
if (check "$split_keyword_scan") 2>/dev/null; then
  fail "negative control passed: split dotnet tool command was not rejected"
fi

# Negative control: a quoted dotnet executable form ("dotnet" tool) must reach the check
# and be rejected.
quoted_cmd_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  '          "dotnet" tool install --global evil-tool' | scan_installs)"
if (check "$quoted_cmd_scan") 2>/dev/null; then
  fail "negative control passed: quoted dotnet executable was not rejected"
fi

# Negative control: variable-invoked tool install ("$DOTNET" tool install) must reach
# the check and be rejected.
var_cmd_scan="$(printf '%s\n' \
  '          "$DOTNET" tool install --global evil-tool' | scan_installs)"
[[ "$var_cmd_scan" == *evil-tool* ]] || fail "negative control found no install under variable invocation"
if (check "$pinned
$var_cmd_scan") 2>/dev/null; then
  fail "negative control passed: variable-invoked tool install was not rejected"
fi

# Positive control: non-install dotnet tool subcommands (list, run, restore, search) must be ignored.
non_install_scan="$(printf '%s\n' \
  '          dotnet tool list' \
  '          dotnet tool run some-tool' \
  '          dotnet tool restore' \
  '          dotnet tool search some-tool' | scan_installs)"
[[ -z "$non_install_scan" ]] || fail "positive control failed: benign dotnet tool subcommands were detected as tool installs: $non_install_scan"
(check "$pinned${non_install_scan:+$'\n'$non_install_scan}") || fail "positive control failed: benign dotnet tool subcommands were rejected"

# Negative control: a tool install placed after a name: command prefix must not be skipped
# as workflow metadata.
name_prefix_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  '          name: || dotnet tool install --global evil-tool' | scan_installs)"
if (check "$name_prefix_scan") 2>/dev/null; then
  fail "negative control passed: tool install after name: prefix was not rejected"
fi

# Negative control: an escaped tool subcommand (dotnet t\ool) must reach the check
# and be rejected.
escaped_tool_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  '          dotnet t\ool install --global evil-tool' | scan_installs)"
if (check "$escaped_tool_scan") 2>/dev/null; then
  fail "negative control passed: escaped tool subcommand was not rejected"
fi

# Negative control: an escaped dotnet executable (d\otnet tool) must reach the check
# and be rejected.
escaped_dotnet_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  '          d\otnet tool install --global evil-tool' | scan_installs)"
if (check "$escaped_dotnet_scan") 2>/dev/null; then
  fail "negative control passed: escaped dotnet executable was not rejected"
fi

# Negative control: a continuation inside a token (dot\ + net) joins to dotnet in Bash, so it
# must reach the check and be rejected.
token_split_scan="$(printf '%s\n' \
  '          dotnet tool install --global dotnet-releaser --version 0.24.0' \
  "          dot\\" \
  '          net tool install --global evil-tool' | scan_installs)"
if (check "$token_split_scan") 2>/dev/null; then
  fail "negative control passed: tool command split inside a token was not rejected"
fi

# Negative control: dotnet-releaser pinned only in an unrelated workflow must not satisfy
# the publishing workflow requirement.
unrelated_workflow='.github/workflows/other.yaml:1:          dotnet tool install --global dotnet-releaser --version 0.24.0'
if (check "$unrelated_workflow") 2>/dev/null; then
  fail "negative control passed: dotnet-releaser pinned in an unrelated workflow satisfied the publishing workflow requirement"
fi

check "$installs"

echo "ok   every .NET tool install is pinned to an exact version"
