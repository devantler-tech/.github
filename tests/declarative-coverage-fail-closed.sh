#!/usr/bin/env bash
#
# Negative control for the rendered Actions-label policy. A label reader may
# emit partial output before failing; that output must never satisfy the policy.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_yq="$(command -v yq)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "declarative-coverage fail-closed test: $*" >&2
  exit 1
}

mkdir "$work/bin"
cat >"$work/bin/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'.spec.forProvider.label[].name'* ]]; then
  printf '%s\n' 'autorelease: pending' 'autorelease: tagged'
  exit 42
fi

exec "$REAL_YQ" "$@"
EOF
chmod +x "$work/bin/yq"

if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" \
  bash "$repo_root/tests/declarative-coverage.sh" >"$work/stdout" 2>"$work/stderr"; then
  fail "partial label output masked a yq read failure"
fi

grep -Fq "actions: failed to read rendered issue labels" "$work/stderr" || {
  echo "declarative-coverage fail-closed test: unexpected failure:" >&2
  cat "$work/stderr" >&2
  exit 1
}

echo "declarative-coverage fail-closed: OK — partial yq output cannot pass"
