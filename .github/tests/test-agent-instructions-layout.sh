#!/usr/bin/env bash
# Keep the canonical entrypoint readable and its on-demand contracts discoverable.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guides=(catalogue workflows validation invariants)
fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
check_layout() (
  local target="$1" guide bytes workflow trigger declared actual
  shopt -s nullglob
  [[ -f "$target/AGENTS.md" && ! -L "$target/AGENTS.md" ]] || { fail 'missing regular instruction entrypoint'; exit 1; }
  bytes="$(wc -c < "$target/AGENTS.md")" || { fail 'unreadable instruction size'; exit 1; }
  ((bytes <= 32268)) || { fail 'instruction entrypoint exceeds 32 KiB with 500 bytes of headroom'; exit 1; }
  grep -qF 'Read each guide before doing the work its row names.' "$target/AGENTS.md" || { fail 'missing read-before instruction'; exit 1; }
  for guide in "${guides[@]}"; do
    [[ -f "$target/.github/agent-guides/$guide.md" && ! -L "$target/.github/agent-guides/$guide.md" ]] || { fail "missing regular $guide guide"; exit 1; }
    grep -qF "](.github/agent-guides/$guide.md)" "$target/AGENTS.md" || { fail "missing $guide guide pointer"; exit 1; }
  done
  for guide in '## Maintenance' '### Conventions' '#### Test jobs'; do
    grep -qxF "$guide" "$target/AGENTS.md" || { fail "missing linked anchor $guide"; exit 1; }
  done
  actual=''
  for workflow in "$target"/.github/workflows/*.{yaml,yml}; do
    trigger="$(yq -o=json '.on' "$workflow" | jq -er '
      if type == "object" then has("workflow_call") | tostring
      elif type == "string" then (. == "workflow_call") | tostring
      elif type == "array" and all(type == "string") then (index("workflow_call") != null) | tostring
      else error("invalid workflow trigger") end')" || { fail 'unreadable workflow triggers'; exit 1; }
    case "$trigger" in
      false) actual+="${workflow##*/}"$'\n' ;;
      true) ;;
      *) fail 'unreadable workflow triggers'; exit 1 ;;
    esac
  done
  actual="$(printf '%s' "$actual" | LC_ALL=C sort)" || { fail 'unreadable workflow inventory'; exit 1; }
  # shellcheck disable=SC2016 # Backticks are literal Markdown code delimiters.
  declared="$(sed -En 's/^[|] `([a-z0-9-]+[.]ya?ml)` [|].*$/\1/p' "$target/.github/agent-guides/catalogue.md" | LC_ALL=C sort)" || { fail 'unreadable workflow inventory'; exit 1; }
  [[ -n "$actual" && "$declared" == "$actual" ]] || { fail 'repository workflow layout differs from actual triggers'; exit 1; }
)
check_layout "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/healthy/.github"
cp "$root/AGENTS.md" "$work/healthy/"
cp -R "$root/.github/agent-guides" "$root/.github/workflows" "$work/healthy/.github/"
reject() {
  local expected="$1"
  if check_layout "$work/bad" > "$work/output" 2>&1; then fail "accepted $expected"; exit 1; fi
  grep -qF "$expected" "$work/output" || { cat "$work/output"; exit 1; }
}
reset_fixture() { rm -rf "$work/bad"; cp -R "$work/healthy" "$work/bad"; }
reset_fixture
head -c 32269 /dev/zero | tr '\0' x > "$work/bad/AGENTS.md"
reject 'headroom'
reset_fixture
sed '/Read each guide before doing the work its row names./d' "$root/AGENTS.md" > "$work/bad/AGENTS.md"
reject 'read-before'
for guide in "${guides[@]}"; do
  reset_fixture
  rm "$work/bad/.github/agent-guides/$guide.md"
  reject "missing regular $guide guide"
  reset_fixture
  sed "\|](.github/agent-guides/$guide.md)|d" "$root/AGENTS.md" > "$work/bad/AGENTS.md"
  reject "missing $guide guide pointer"
done
reset_fixture
rm "$work/bad/.github/agent-guides/workflows.md"
ln -s "$work/healthy/.github/agent-guides/workflows.md" "$work/bad/.github/agent-guides/workflows.md"
reject 'missing regular workflows guide'
reset_fixture
sed '/^#### Test jobs$/d' "$root/AGENTS.md" > "$work/bad/AGENTS.md"
reject 'missing linked anchor'
reset_fixture
printf 'name: omitted\non: {push: {}}\njobs: {}\n' > "$work/bad/.github/workflows/omitted.yaml"
reject 'repository workflow layout'
reset_fixture
printf 'name: omitted\non: {push: {}}\njobs: {}\n' > "$work/bad/.github/workflows/omitted.yml"
reject 'repository workflow layout'
reset_fixture
printf 'name: ambiguous\non: {push: {}}\njobs: {}\n---\nname: second\non: {workflow_call: {}}\njobs: {}\n' > "$work/bad/.github/workflows/ambiguous.yaml"
reject 'unreadable workflow triggers'
reset_fixture
printf 'name: malformed\non: null\njobs: {}\n' > "$work/bad/.github/workflows/malformed.yaml"
reject 'unreadable workflow triggers'
mkdir "$work/bin"
real_yq="$(command -v yq)"
cat > "$work/bin/yq" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_YQ" "$@"
exit 42
WRAPPER
chmod +x "$work/bin/yq"
reset_fixture
if REAL_YQ="$real_yq" PATH="$work/bin:$PATH" check_layout "$work/bad" > "$work/output" 2>&1; then fail 'accepted plausible output from a failed reader'; exit 1; fi
grep -qF 'unreadable workflow triggers' "$work/output"
rm "$work/bin/yq"
for reader in wc sed sort; do
  real_reader="$(command -v "$reader")"
  cat > "$work/bin/$reader" <<'WRAPPER'
#!/usr/bin/env bash
"$REAL_READER" "$@"
exit 42
WRAPPER
  chmod +x "$work/bin/$reader"
  if REAL_READER="$real_reader" PATH="$work/bin:$PATH" check_layout "$work/bad" > "$work/output" 2>&1; then fail "accepted plausible output from failed $reader"; exit 1; fi
  grep -qF 'unreadable' "$work/output"
  rm "$work/bin/$reader"
done
printf 'PASS: instruction size, guide discovery, retained anchors and repository workflow layout; 20 negative controls\n'
