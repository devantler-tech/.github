#!/usr/bin/env bash
# The version-pin census (#627) passes on this repository and rejects every way a
# pin can be mutable, untracked, unlisted or stale in an isolated fixture tree.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
census="$root/.github/scripts/version-pin-census.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "::error::$*" >&2; exit 1; }
sha=0123456789abcdef0123456789abcdef01234567
digest=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

# The real catalogue: every pin is tracked or listed, and stale-repos runs by digest.
rc=0
bash "$census" "$root" > "$scratch/repo.tsv" 2> "$scratch/repo.err" || rc=$?
[[ "$rc" == 0 ]] || fail "the catalogue census failed ($rc): $(grep '^violation' "$scratch/repo.tsv" | head -5; cat "$scratch/repo.err")"
grep -q $'^tracked\taction\t' "$scratch/repo.tsv" || fail 'the census found no tracked action pins'
grep -q $'^manifest\timage\t.github/workflows/stale-repository-identifier.yaml:[0-9]*\tghcr.io/github-community-projects/stale_repos:v9.1.1@sha256:' "$scratch/repo.tsv" ||
  fail 'stale-repos must run its image by digest'

base="$scratch/base"
mkdir -p "$base/.github/workflows" "$base/actions/a" "$base/mod-tracked" "$base/mod-frozen" "$base/mod-local"
cat > "$base/.github/dependabot.yml" <<'YAML'
version: 2
updates:
  - package-ecosystem: github-actions
    directories: ["/", "/actions/*"]
  - package-ecosystem: gomod
    directory: /mod-tracked
  - package-ecosystem: gomod
    directory: /mod-frozen
    ignore:
      - dependency-name: "*"
YAML
cat > "$base/.github/workflows/w.yaml" <<YAML
jobs:
  build:
    runs-on: ubuntu-latest
    services:
      db:
        image: postgres:17@$digest
    steps:
      # uses: example/ignored@v1 is a comment, not a pin.
      - uses: example/action@$sha # v1.2.3
      - uses: ./local-action
      - uses: docker://ghcr.io/example/tool:v2@$digest
      - uses: actions/setup-node@$sha # v6.0.0
        with:
          node-version: 22
      - run: npx tool@1.2.3
      - run: docker pull "\$HELPER_IMAGE"
        env:
          HELPER_IMAGE: ghcr.io/example/helper:v1@$digest
  fixture:
    runs-on: ubuntu-latest
    services:
      pg:
        image: \${{ inputs.fixture == 'true' && 'postgres:16@$digest' || '' }}
    steps:
      - run: true
YAML
cat > "$base/actions/a/action.yaml" <<YAML
runs:
  using: composite
  steps:
    - uses: example/action@$sha # v1.2.3
YAML
printf 'module example.com/tracked\n\ngo 1.26\n\nrequire example.com/dep v1.0.0\n' > "$base/mod-tracked/go.mod"
printf 'module example.com/frozen\n\ngo 1.26\n\nrequire (\n\texample.com/old v0.3.0\n)\n' > "$base/mod-frozen/go.mod"
printf 'module example.com/local\n\ngo 1.26\n\nrequire example.com/sibling v0.0.0\n\nreplace example.com/sibling => ../mod-tracked\n' > "$base/mod-local/go.mod"
jq -n --arg d "$digest" '{schema: 1, pins: [
  {kind: "image", pin: ("postgres:17@" + $d), files: [".github/workflows/w.yaml"], refresh: "Resolve the new tag digest in a reviewed PR."},
  {kind: "image", pin: ("ghcr.io/example/tool:v2@" + $d), files: [".github/workflows/w.yaml"], refresh: "Resolve the new tag digest in a reviewed PR."},
  {kind: "image", pin: ("ghcr.io/example/helper:v1@" + $d), files: [".github/workflows/w.yaml"], refresh: "Resolve the new tag digest in a reviewed PR."},
  {kind: "image", pin: ("postgres:16@" + $d), files: [".github/workflows/w.yaml"], refresh: "Resolve the new tag digest in a reviewed PR."},
  {kind: "tool", pin: "node-version: 22", files: [".github/workflows/w.yaml"], refresh: "Move to the next LTS major when needed."},
  {kind: "tool", pin: "tool@1.2.3", files: [".github/workflows/w.yaml"], refresh: "Compare with the latest release upstream."},
  {kind: "module", pin: "example.com/frozen", files: ["mod-frozen/go.mod"], refresh: "Frozen on purpose for a vulnerability fixture."}
]}' > "$base/.github/version-pins.json"

run_case() { # name: copies the base tree into $case_root for the caller to mutate first
  case_root="$scratch/$1"
  rm -rf "$case_root"
  cp -R "$base" "$case_root"
}
expect() { # name exit [row-pattern]
  local name="$1" want="$2" pattern="${3:-}" rc=0
  bash "$census" "$case_root" > "$scratch/$name.tsv" 2> "$scratch/$name.err" || rc=$?
  [[ "$rc" == "$want" ]] || fail "$name: census exited $rc, want $want: $(cat "$scratch/$name.tsv" "$scratch/$name.err")"
  [[ -z "$pattern" ]] || grep -qE "$pattern" "$scratch/$name.tsv" "$scratch/$name.err" || fail "$name: missing '$pattern'"
}

run_case baseline
expect baseline 0
[[ "$(grep -c $'^tracked\taction\t' "$scratch/baseline.tsv")" == 3 ]] || fail 'baseline: three tracked action pins expected'
[[ "$(grep -c '^manifest' "$scratch/baseline.tsv")" == 7 ]] || fail 'baseline: seven listed pins expected'
grep -q $'^tracked\tmodule\tmod-tracked/go.mod:1\texample.com/tracked$' "$scratch/baseline.tsv" || fail 'baseline: tracked module missing'
! grep -q 'example.com/local\|ignored' "$scratch/baseline.tsv" || fail 'baseline: local replacements and comments are not pins'

run_case tag-ref; sed -i.bak "s/example\/action@$sha # v1.2.3/example\/action@v1/" "$case_root/actions/a/action.yaml"
expect tag-ref 1 $'^violation\taction\tactions/a/action.yaml:4\texample/action@v1 \\(mutable: not a full SHA\\)'
run_case no-version-comment; sed -i.bak "s/# v1.2.3/# main/" "$case_root/actions/a/action.yaml"
expect no-version-comment 1 $'^violation\taction\tactions/a/action.yaml:4'
run_case uncovered-dir; mkdir -p "$case_root/.github/fixtures/f"; cp "$case_root/actions/a/action.yaml" "$case_root/.github/fixtures/f/action.yaml"
expect uncovered-dir 1 $'^violation\taction\t.github/fixtures/f/action.yaml:4'
run_case docker-tag; sed -i.bak "s#docker://ghcr.io/example/tool:v2@$digest#docker://ghcr.io/example/tool:v2#" "$case_root/.github/workflows/w.yaml"
expect docker-tag 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\tghcr.io/example/tool:v2 \\(mutable: no digest\\)'
run_case service-tag; sed -i.bak "s#image: postgres:17@$digest#image: postgres:17#" "$case_root/.github/workflows/w.yaml"
expect service-tag 1 $'^violation\timage\t.github/workflows/w.yaml:6\tpostgres:17 \\(mutable: no digest\\)'
run_case expression-image; sed -i.bak "s#image: postgres:17@$digest#image: \${{ matrix.image }}#" "$case_root/.github/workflows/w.yaml"
expect expression-image 1 'unverifiable expression'
run_case unlisted-tool; printf '      - run: go install example.com/cmd/lint@v0.5.0\n' >> "$case_root/.github/workflows/w.yaml"
expect unlisted-tool 1 $'^violation\ttool\t.github/workflows/w.yaml:[0-9]+\texample.com/cmd/lint@v0.5.0'
run_case env-version; printf '        env:\n          LINT_VERSION: "1.4.0"\n' >> "$case_root/.github/workflows/w.yaml"
expect env-version 1 $'^violation\ttool\t.github/workflows/w.yaml:[0-9]+\tLINT_VERSION: 1.4.0'
run_case block-version; printf '      - uses: actions/setup-dotnet@%s # v6.0.0\n        with:\n          dotnet-version: |\n            9.0.319\n' "$sha" >> "$case_root/.github/workflows/w.yaml"
expect block-version 1 $'^violation\ttool\t.github/workflows/w.yaml:[0-9]+\tdotnet-version: 9.0.319'
run_case untracked-module; mkdir -p "$case_root/mod-new"; printf 'module example.com/new\n\nrequire example.com/dep v1.0.0\n' > "$case_root/mod-new/go.mod"
expect untracked-module 1 $'^violation\tmodule\tmod-new/go.mod:1\texample.com/new'
run_case frozen-unlisted; jq '.pins |= map(select(.kind != "module"))' "$base/.github/version-pins.json" > "$case_root/.github/version-pins.json"
expect frozen-unlisted 1 $'^violation\tmodule\tmod-frozen/go.mod:1\texample.com/frozen'
run_case stale-entry; sed -i.bak 's/tool@1.2.3/tool@1.2.4/' "$case_root/.github/workflows/w.yaml"
expect stale-entry 1 'stale manifest entry tool tool@1.2.3 in .github/workflows/w.yaml'
run_case malformed; jq '.pins[0].refresh = "short"' "$base/.github/version-pins.json" > "$case_root/.github/version-pins.json"
expect malformed 2 'does not match its schema'
run_case env-image; printf '      - run: echo\n        env:\n          OTHER_IMAGE: alpine:3\n' >> "$case_root/.github/workflows/w.yaml"
expect env-image 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\talpine:3 \\(mutable: no digest\\)'
run_case docker-run; printf '      - run: docker run --rm --name probe busybox:1 true\n' >> "$case_root/.github/workflows/w.yaml"
expect docker-run 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\tbusybox:1 \\(mutable: no digest\\)'
run_case docker-run-continued; printf '      - run: |\n          docker run --rm \\\n            --env A=1 \\\n            busybox:1 true\n' >> "$case_root/.github/workflows/w.yaml"
expect docker-run-continued 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\tbusybox:1 \\(mutable: no digest\\)'
run_case expression-branch; sed -i.bak "s/|| '' }}/|| 'postgres:latest' }}/" "$case_root/.github/workflows/w.yaml"
expect expression-branch 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\tpostgres:latest \\(mutable: no digest\\)'
run_case unlisted-env-digest; printf '      - run: echo\n        env:\n          NEW_IMAGE: ghcr.io/example/new:v1@%s\n' "$digest" >> "$case_root/.github/workflows/w.yaml"
expect unlisted-env-digest 1 $'^violation\timage\t.github/workflows/w.yaml:[0-9]+\tghcr.io/example/new:v1@sha256:'
run_case nested-action; mkdir -p "$case_root/actions/a/b"; cp "$case_root/actions/a/action.yaml" "$case_root/actions/a/b/action.yaml"
expect nested-action 1 $'^violation\taction\tactions/a/b/action.yaml:4'
run_case no-pull-requests; sed -i.bak 's#directories: \["/", "/actions/\*"\]#directories: ["/", "/actions/*"]\n    open-pull-requests-limit: 0#' "$case_root/.github/dependabot.yml"
expect no-pull-requests 1 $'^violation\taction\tactions/a/action.yaml:4'
run_case template; mkdir -p "$case_root/workflow-templates"; printf 'jobs:\n  a:\n    steps:\n      - uses: example/action@%s # v1.2.3\n' "$sha" > "$case_root/workflow-templates/t.yml"
expect template 1 $'^violation\taction\tworkflow-templates/t.yml:4'
run_case no-dependabot; rm "$case_root/.github/dependabot.yml"
expect no-dependabot 2 'missing'

echo 'Version-pin census: catalogue clean; mutable, untracked, unlisted, stale and unreadable controls rejected'
