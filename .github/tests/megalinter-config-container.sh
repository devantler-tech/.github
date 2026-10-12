#!/usr/bin/env bash
# Required native CI executes the production-pinned Docker action, not a loader
# reimplementation. Its JSON receipt must contain real per-file checker results.
set -euo pipefail
scenario="${SCENARIO:?SCENARIO is required}"
workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
fixture="$workspace/.github/tests/megalinter-bad-fixture"
probe="$fixture/config-probe"
case "$scenario" in root|nested|absent|malformed|finding) ;;
  *) echo 'Unknown configuration scenario' >&2; exit 1 ;;
esac
case "${1:-}" in
  prepare)
    [[ "$(git -C "$workspace" rev-parse --show-toplevel)" == "$workspace" ]]
    [[ -f "$workspace/.mega-linter.yml" && ! -L "$workspace/.mega-linter.yml" ]]
    mkdir "$probe"
    cp "$fixture/config-probe-checked.json" "$probe/config-probe-checked.json"
    cp "$fixture/bad.json" "$probe/config-probe-bad.json"
    cp "$fixture/config-probe.yml" "$workspace/.mega-linter.yml"
    container_workspace=/github/workspace
    case "$scenario" in root) ;;
      *) container_workspace=/github/workspace/.github/tests/megalinter-bad-fixture/config-probe ;;
    esac
    case "$scenario" in
      absent) rm "$workspace/.mega-linter.yml" ;;
      malformed) cp "$fixture/config-probe-malformed.yml" "$workspace/.mega-linter.yml" ;;
      finding) cp "$fixture/bad.json" "$probe/config-probe-checked.json" ;;
    esac
    printf 'workspace=%s\n' "$container_workspace" >>"${GITHUB_OUTPUT:?}"
    ;;
  assert)
    outcome="${OUTCOME:?OUTCOME is required}"
    reports="$workspace/megalinter-bad-fixture-reports"
    if [[ "$scenario" == malformed ]]; then
      [[ "$outcome" == failure ]]
      # The action has already pulled this image at its immutable action pin.
      # Reuse its LOCAL image id with networking disabled to capture the precise
      # parser failure, rather than accepting an image-pull/runner error as RED.
      image="$(docker image inspect ghcr.io/oxsecurity/megalinter-go:v10.1.0 --format '{{.Id}}')"
      [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]]
      log="$workspace/megalinter-malformed-config.log"
      status=0
      timeout 120 docker run --rm --network none \
        --volume "$workspace:/github/workspace" --workdir /github/workspace \
        --env GITHUB_WORKSPACE=/github/workspace \
        --env DEFAULT_WORKSPACE=/github/workspace/.github/tests/megalinter-bad-fixture/config-probe \
        --env MEGALINTER_CONFIG=/github/workspace/.mega-linter.yml \
        "$image" >"$log" 2>&1 || status=$?
      [[ "$status" -ne 0 && "$status" -ne 124 ]]
      grep -F 'yaml.parser.ParserError' "$log" >/dev/null
      grep -F '/github/workspace/.mega-linter.yml' "$log" >/dev/null
      echo 'PASS: actual pinned loader rejects malformed repository configuration'
      exit 0
    fi
    report="$reports/mega-linter-report.json"
    [[ -f "$report" && ! -L "$report" ]]
    # The JSON_JSONLINT identity and per-file results are from v10.1.0's real
    # JsonReporter/Linter schema. Empty analysis and generic action failures fail.
    jq -e '[.linters[] | select(.name == "JSON_JSONLINT" and .is_active == true)] |
      length == 1 and .[0].files_number > 0 and (.[0].files_lint_results | length) > 0' "$report" >/dev/null
    case "$scenario" in
      root|nested)
        [[ "$outcome" == success ]]
        jq -e '.return_code == 0 and
          ([.linters[] | select(.name == "JSON_JSONLINT")] | .[0] |
            .return_code == 0 and .files_number == 1 and
            (.files_lint_results | length) == 1 and
            .files_lint_results[0].status_code == 0 and
            (.files_lint_results[0].file | endswith("/config-probe-checked.json")))' "$report" >/dev/null
        ;;
      absent|finding)
        [[ "$outcome" == failure ]]
        expected='config-probe-bad.json'
        [[ "$scenario" != finding ]] || expected='config-probe-checked.json'
        jq -e --arg expected "/$expected" '.return_code != 0 and
          ([.linters[] | select(.name == "JSON_JSONLINT")] | .[0] |
            .return_code != 0 and any(.files_lint_results[];
              (.file | endswith($expected)) and .status_code != null and .status_code != 0))' "$report" >/dev/null
        ;;
    esac
    echo "PASS: actual configuration/checker receipt for $scenario"
    ;;
  *) echo 'Expected prepare or assert' >&2; exit 1 ;;
esac
