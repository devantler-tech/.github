#!/usr/bin/env bash
# Require the completed fixture verdict for the exact scenario and request count.
set -euo pipefail
[[ $# == 3 && "$3" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid scanner verdict arguments' >&2; exit 1; }
expected="PASS: real pinned scanner — $2 ($3 requests)"
grep -Fxq -- "$expected" "$1" || { echo 'FAIL: completed scanner scenario verdict is missing' >&2; exit 1; }
