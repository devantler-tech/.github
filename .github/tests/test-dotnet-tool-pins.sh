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
# commands cannot bypass detection. Whole-line comments are ignored.
scan_installs() {
  awk '
    FNR == 1 { buf = ""; start_line = 0 }
    /^[[:space:]]*#/ { next }
    /[[:space:]]*\\[[:space:]]*$/ {
      sub(/[[:space:]]*\\[[:space:]]*$/, "")
      if (buf == "") { start_line = FNR }
      buf = buf $0 " "
      next
    }
    {
      if (buf != "") {
        line = buf $0
        buf = ""
        fnr = start_line
      } else {
        line = $0
        fnr = FNR
      }
      if (line ~ /dotnet[[:space:]]+tool[[:space:]]+(install|update)/) {
        print (FILENAME ? FILENAME : "stdin") ":" fnr ":" line
      }
    }
  ' "$@"
}

target_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && target_files+=("$f")
done < <(find .github/workflows .github/actions actions .scripts scripts -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \) 2>/dev/null | sort)

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

# Negative control: dotnet-releaser pinned only in an unrelated workflow must not satisfy
# the publishing workflow requirement.
unrelated_workflow='.github/workflows/other.yaml:1:          dotnet tool install --global dotnet-releaser --version 0.24.0'
if (check "$unrelated_workflow") 2>/dev/null; then
  fail "negative control passed: dotnet-releaser pinned in an unrelated workflow satisfied the publishing workflow requirement"
fi

check "$installs"

echo "ok   every .NET tool install is pinned to an exact version"
