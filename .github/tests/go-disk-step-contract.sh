#!/usr/bin/env bash
# Execute the production steps in both states; assert the original Go arguments.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="${1:-$root/.github/workflows/validate-go-project.yaml}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cp "$root/.github/scripts/measure-go-disk.sh" "$scratch/measure-go-disk.sh"
cat > "$scratch/bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DISK_COMMAND_ARGS"
exit "${GO_FIXTURE_EXIT:-0}"
EOF
chmod +x "$scratch/bin/go"
export PATH="$scratch/bin:$PATH" DISK_COMMAND_ARGS="$scratch/args" RUNNER_TEMP="$scratch"
for enabled in false true; do
  : > "$scratch/args"
  for job in build test coverage; do
    yq -r ".jobs.$job.steps[] | select(.name == \"🛠️ Build\" or .name == \"🧪 Test\" or .name == \"📄 Generate coverage\") | .run" "$workflow" > "$scratch/step"
    [[ -s "$scratch/step" ]] || { echo "Missing $job command" >&2; exit 1; }
    MEASURE_DISK_USAGE="$enabled" bash -euo pipefail "$scratch/step" > /dev/null
    rc=0
    MEASURE_DISK_USAGE="$enabled" GO_FIXTURE_EXIT=19 bash -euo pipefail "$scratch/step" > /dev/null || rc=$?
    [[ "$rc" == 19 ]] || { echo "$job $enabled concealed the Go failure" >&2; exit 1; }
  done
  diff -u <(printf '%s\n' 'build -v ./...' 'build -v ./...' 'test ./...' 'test ./...' 'test -race -coverprofile=coverage.txt -covermode=atomic ./...' 'test -race -coverprofile=coverage.txt -covermode=atomic ./...') "$scratch/args"
done
