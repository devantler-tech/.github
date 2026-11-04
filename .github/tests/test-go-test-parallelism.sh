#!/usr/bin/env bash
# An opted-in consumer must reach the real resolver; invalid declarations must fail.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
yq -r '.jobs.changes.steps[] | select(.id == "module-directory") | .run' \
  "$root/.github/workflows/validate-go-project.yaml" >"$work/resolve.sh"

fixture="$work/consumer"
mkdir -p "$fixture"
git -C "$fixture" init -q
printf 'module example.invalid/parallelism\n\ngo 1.26.0\n' >"$fixture/go.mod"
git -C "$fixture" add go.mod
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm fixture

prepare() {
  local source="$1"
  rm -f -- "$fixture/.go-test-execution.json"
  if [ "$source" != absent ]; then
    printf '%s\n' "$source" >"$fixture/.go-test-execution.json"
    git -C "$fixture" add .go-test-execution.json
    git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -qm declaration
  else
    git -C "$fixture" rm -q --cached --ignore-unmatch .go-test-execution.json
    git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -qm absent
  fi
  mkdir -p "$fixture/.devantler-tech-go-module/.github/scripts"
  cp "$root/.github/scripts/resolve-go-module.sh" "$fixture/.devantler-tech-go-module/.github/scripts/"
  if [ -f "$root/.github/scripts/resolve-go-test-parallelism.sh" ]; then
    cp "$root/.github/scripts/resolve-go-test-parallelism.sh" "$fixture/.devantler-tech-go-module/.github/scripts/"
  fi
  : >"$work/output"
}

resolve() {
  local direct="$1" opted_in="$2" parallelism="$3"
  (cd "$fixture" && GITHUB_WORKSPACE="$fixture" GITHUB_OUTPUT="$work/output" \
    MODULE_DIRECTORY='' DIRECT_REQUIRED_RUN="$direct" RESOLVE_REQUIRED=true \
    TEST_PARALLELISM_OPT_IN="$opted_in" TEST_PARALLELISM_INPUT="$parallelism" \
    bash "$work/resolve.sh") >"$work/stdout" 2>"$work/stderr"
}

expect() {
  local description="$1" expected="$2" direct="$3" opted_in="$4" parallelism="$5"
  resolve "$direct" "$opted_in" "$parallelism" || {
    printf 'FAIL: %s was refused\n' "$description" >&2
    cat "$work/stderr" >&2
    exit 1
  }
  local actual
  actual="$(sed -n 's/^test-parallelism=//p' "$work/output")"
  [ "$actual" = "$expected" ] || {
    printf 'FAIL: %s selected <%s>, expected <%s>\n' "$description" "$actual" "$expected" >&2
    exit 1
  }
}

prepare absent
expect 'undeclared required consumer keeps defaults' '' true '' ''
prepare '{"version":1,"parallelism":8}'
expect 'tracked required consumer selects eight workers' 8 true '' ''
prepare '{"version":1,"parallelism":2}'
expect 'tracked required consumer selects two workers' 2 true '' ''
prepare '{malformed'
expect 'called false ignores consumer declaration' '' false false 8
prepare absent
expect 'called true selects its bounded input' 8 false true 8

for declaration in \
  '{"version":1,"parallelism":0}' \
  '{"version":1,"parallelism":9}' \
  '{"version":1,"parallelism":1.5}' \
  '{"version":1,"parallelism":"8"}' \
  '{"version":1}' \
  '{"parallelism":8}' \
  '{"version":1,"parallelism":8} {}' \
  '{"version":1,"parallelism":8} {"version":1,"parallelism":8}' \
  '[{"version":1,"parallelism":8}]' \
  '{"version":1,"parallelism":8,"extra":true}' \
  '{"version":1,"parallelism":2,"parallelism":8}' \
  '{"version":2,"parallelism":8}' \
  '{malformed'; do
  prepare "$declaration"
  if resolve true '' ''; then
    echo 'FAIL: invalid required declaration was accepted' >&2
    exit 1
  fi
done
prepare absent
if resolve false true '8; echo injected'; then
  echo 'FAIL: arbitrary test argument was accepted' >&2
  exit 1
fi

# Bind direct declarations to the real committed file, not a working-tree substitute.
refuse_declaration() {
  if resolve true '' ''; then
    echo 'FAIL: uncommitted, missing or linked declaration was accepted' >&2
    exit 1
  fi
}
prepare absent
printf '{"version":1,"parallelism":8}\n' >"$fixture/.go-test-execution.json"
refuse_declaration
prepare '{"version":1,"parallelism":8}'
printf '{"version":1,"parallelism":2}\n' >"$fixture/.go-test-execution.json"
refuse_declaration
prepare '{"version":1,"parallelism":8}'
rm -- "$fixture/.go-test-execution.json"
refuse_declaration
prepare absent
ln -s go.mod "$fixture/.go-test-execution.json"
git -C "$fixture" add .go-test-execution.json
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm linked
refuse_declaration
prepare absent

# Input-free consumers may use a sole tracked module inside a dot-prefixed path.
mkdir -p "$fixture/.github/nested"
git -C "$fixture" mv go.mod .github/nested/go.mod
printf '{"version":1,"parallelism":8}\n' >"$fixture/.github/nested/.go-test-execution.json"
git -C "$fixture" add .github/nested/.go-test-execution.json
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -qm nested
expect 'nested required consumer selects its module declaration' 8 true '' ''

# Exercise each real command branch at the Go CLI boundary.
mkdir -p "$work/bin" "$work/runner"
cat >"$work/bin/go" <<'GO'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$GO_CAPTURE"
GO
cat >"$work/runner/measure-go-disk.sh" <<'MEASURE'
#!/usr/bin/env bash
case "$1" in test|coverage) shift ;; *) exit 90 ;; esac
exec "$@"
MEASURE
chmod +x "$work/bin/go"
for job in test coverage; do
  if [ "$job" = test ]; then label='🧪 Test'; else label='📄 Generate coverage'; fi
  JOB="$job" LABEL="$label" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == strenv(LABEL)) | .run' \
    "$root/.github/workflows/validate-go-project.yaml" >"$work/command.sh"
  for fixture_enabled in false true; do
    for measured in false true; do
      for parallelism in '' 2 8; do
        rm -f -- "$work/argv"
        PATH="$work/bin:$PATH" GO_CAPTURE="$work/argv" RUNNER_TEMP="$work/runner" \
          FIXTURE_ENABLED="$fixture_enabled" MEASURE_DISK_USAGE="$measured" \
          GO_DISK_OBSERVATION=false GO_TEST_PARALLELISM="$parallelism" \
          bash "$work/command.sh"
        args=()
        while IFS= read -r -d '' argument; do args+=("$argument"); done <"$work/argv"
        last=$(("${#args[@]}" - 1))
        [ "${args[0]}" = test ] && [ "${args[last]}" = './...' ] || {
          echo 'FAIL: complete Go test scope was changed' >&2
          exit 1
        }
        selected=''
        for ((index = 0; index < ${#args[@]}; index++)); do
          if [ "${args[index]}" = -parallel ]; then selected="${args[index + 1]}"; fi
        done
        [ "$selected" = "$parallelism" ] || {
          printf 'FAIL: %s fixture=%s measured=%s selected <%s>, expected <%s>\n' \
            "$job" "$fixture_enabled" "$measured" "$selected" "$parallelism" >&2
          exit 1
        }
        if [ "$job" = coverage ]; then
          for required in -race -coverprofile=coverage.txt -covermode=atomic; do
            present=false
            for argument in "${args[@]}"; do [ "$argument" != "$required" ] || present=true; done
            [ "$present" = true ] || {
              echo 'FAIL: coverage instrumentation changed' >&2
              exit 1
            }
          done
        fi
        if [ "$fixture_enabled" = true ]; then
          [[ " ${args[*]} " == *' -count=1 '* ]] || {
            echo 'FAIL: fixture cache refusal changed' >&2
            exit 1
          }
        fi
      done
    done
  done
  rm -f -- "$work/argv"
  if PATH="$work/bin:$PATH" GO_CAPTURE="$work/argv" RUNNER_TEMP="$work/runner" \
    FIXTURE_ENABLED=false MEASURE_DISK_USAGE=false GO_DISK_OBSERVATION=false \
    GO_TEST_PARALLELISM='8; echo injected' bash "$work/command.sh"; then
    echo 'FAIL: unvalidated command parallelism was accepted' >&2
    exit 1
  fi
  [ ! -e "$work/argv" ] || {
    echo 'FAIL: Go ran after scheduling refusal' >&2
    exit 1
  }
done

echo 'PASS: bounded Go test parallelism, default behavior and declaration refusals'
