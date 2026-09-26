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

# Joins shell lines continued with trailing backslashes before matching, so split
# commands cannot bypass detection. Whole-line comments and step names are ignored,
# but any pending continuation buffer is flushed before skipping comments, switching
# files or exiting. YAML folded scalars (run: > or run: >-) are folded so multiline
# commands are checked.
scan_installs() {
  awk '
    function norm(s,   t) {
      t = s
      gsub(/\\/, "", t)
      gsub(/["'\'']/, "", t)
      return t
    }

    function is_tool_cmd(s,   t) {
      t = norm(s)
      return (t ~ /dotnet[[:space:]]+tool/ || t ~ /^[[:space:]]*tool[[:space:]]+(install|update)([[:space:]]|$)/)
    }

    function flush_buf() {
      if (buf != "") {
        if (is_tool_cmd(buf)) {
          print (FILENAME ? FILENAME : "stdin") ":" start_line ":" buf
        }
        buf = ""
        start_line = 0
      }
      glue = 0
    }

    function flush_folded() {
      if (folded_buf != "") {
        if (is_tool_cmd(folded_buf)) {
          print (FILENAME ? FILENAME : "stdin") ":" folded_start ":" folded_buf
        }
        folded_buf = ""
        folded_indent = 0
        in_folded = 0
      }
    }

    FNR == 1 { flush_buf(); flush_folded() }
    /^[[:space:]]*#/ {
      flush_buf()
      next
    }
    /^[[:space:]]*-?[[:space:]]*name:/ {
      flush_buf()
      if (!is_tool_cmd($0)) {
        next
      }
    }

    in_folded {
      match($0, /^[[:space:]]*/)
      cur_indent = RLENGTH
      if (cur_indent >= folded_indent && NF > 0) {
        folded_buf = (folded_buf == "" ? "" : folded_buf " ") $0
        sub(/^[[:space:]]*/, "", folded_buf)
        next
      } else if (NF == 0) {
        next
      } else {
        flush_folded()
      }
    }

    # A folded header may carry chomping/indentation indicators (>-, >2, >2-) and a comment.
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*>[1-9+-]*([[:space:]]+#.*)?[[:space:]]*$/ {
      flush_buf()
      in_folded = 1
      match($0, /^[[:space:]]*/)
      folded_indent = RLENGTH + 2
      folded_start = FNR
      folded_buf = ""
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
        print (FILENAME ? FILENAME : "stdin") ":" fnr ":" line
      }
    }
    END {
      flush_buf()
      flush_folded()
    }
  ' "$@"
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

# Every line that mentions installing or updating a .NET tool, except whole-line comments.
installs="$(scan_installs "${target_files[@]}")"
[[ -n "$installs" ]] || fail "found no 'dotnet tool install' lines — refusing to pass vacuously"

# check <grep -n lines>: fail on any line outside the allowed shape, or when publish-dotnet-library.yaml
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

# Negative control: an unpinned install split across lines in a YAML folded scalar (run: >)
# must be detected and rejected.
folded_scalar_scan="$(printf '%s\n' \
  '    - name: Publish' \
  '      run: >' \
  '        dotnet tool' \
  '        install --global evil-tool' | scan_installs)"
if (check "$pinned
$folded_scalar_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install split across folded scalar lines was not rejected"
fi

# Negative control: a folded header with indicators and a trailing comment still folds.
commented_folded_scan="$(printf '%s\n' \
  '    - name: Publish' \
  '      run: >- # explanation' \
  '        dotnet' \
  '        tool' \
  '        install --global evil-tool' | scan_installs)"
if (check "$pinned
$commented_folded_scan") 2>/dev/null; then
  fail "negative control passed: unpinned install under a commented folded header was not rejected"
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
