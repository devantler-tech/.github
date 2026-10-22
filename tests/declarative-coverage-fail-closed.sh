#!/usr/bin/env bash
#
# Negative control for rendered label-dimension coverage. A reader may emit
# partial output before failing; that output must never satisfy the policy.

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

if [[ "$*" == *'select(.kind=="IssueLabels")'* ]]; then
  printf '%s\n' '.github' 'monorepo'
  exit 42
fi

exec "$REAL_YQ" "$@"
EOF
chmod +x "$work/bin/yq"

if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" \
  bash "$repo_root/tests/declarative-coverage.sh" >"$work/stdout" 2>"$work/stderr"; then
  fail "partial dimension output masked a yq read failure"
fi

grep -Fq "dimension 'labels': yq selector failed" "$work/stderr" || {
  echo "declarative-coverage fail-closed test: unexpected failure:" >&2
  cat "$work/stderr" >&2
  exit 1
}

echo "declarative-coverage fail-closed: OK — partial yq output cannot pass"
