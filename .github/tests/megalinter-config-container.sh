#!/usr/bin/env bash
# Required native CI executes the production-pinned Docker action, not a loader
# reimplementation. Its TAP receipt must contain real per-file checker results.
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
    report="$reports/tap/mega-linter-JSON_JSONLINT.tap"
    if [[ ! -f "$report" || -L "$report" ]]; then
      echo 'FAIL: actual checker TAP receipt is missing or linked' >&2
      exit 1
    fi
    # Only synthetic fixture data is printed. Preserve the actual native bytes
    # when the observer fails so schema drift cannot be diagnosed by inference.
    sed -n '1,120p' "$report"
    case "$scenario" in
      root|nested) [[ "$outcome" == success ]] ;;
      absent|finding) [[ "$outcome" == failure ]] ;;
    esac
    # TAP is emitted by the actual pinned JSON checker. Require the complete
    # plan, exact prepared paths and successful analysis or its parser finding;
    # generic action failures, zero analysis and truncated reports cannot pass.
    prefix=''
    [[ "$scenario" != root ]] || prefix='.github/tests/megalinter-bad-fixture/config-probe/'
    awk -v scenario="$scenario" -v prefix="$prefix" '
      BEGIN { expected = scenario == "absent" ? 2 : 1 }
      NR == 1 { if ($0 != "TAP version 13") exit 1; next }
      NR == 2 { if ($0 != "1.." expected) exit 1; next }
      /^(not )?ok [1-9][0-9]* - / {
        if (pending || diagnostic) exit 1
        status = $0 ~ /^not ok/ ? "not ok" : "ok"
        entry = $0
        sub(/^(not )?ok /, "", entry)
        number = entry
        sub(/ - .*/, "", number)
        file = entry
        sub(/^[0-9]+ - /, "", file)
        count++
        if (number != count || seen[file]++) exit 1
        checked = file == prefix "config-probe-checked.json"
        bad = file == prefix "config-probe-bad.json"
        if (scenario == "root" || scenario == "nested") {
          if (!checked || status != "ok") exit 1
        } else if (scenario == "finding") {
          if (!checked || status != "not ok") exit 1
        } else if (!(checked && status == "ok") && !(bad && status == "not ok")) exit 1
        if (status == "not ok") { failures++; pending = 1 }
        next
      }
      $0 == "  ---" { if (!pending || diagnostic) exit 1; diagnostic = 1; next }
      /^  message: / {
        expected_message = "  message: File  " file "\\nParse error on line "
        if (diagnostic != 1 || index($0, expected_message) != 1 ||
            index($0, "No value found for key \"deliberatelyInvalid\"") == 0) exit 1
        diagnostic = 2
        next
      }
      $0 == "  ..." { if (diagnostic != 2) exit 1; diagnostic = 0; pending = 0; next }
      { exit 1 }
      END {
        if (NR < 3 || count != expected || diagnostic || pending) exit 1
        if ((scenario == "root" || scenario == "nested") && failures) exit 1
        if ((scenario == "absent" || scenario == "finding") && failures != 1) exit 1
      }
    ' "$report"
    echo "PASS: actual configuration/checker receipt for $scenario"
    ;;
  *) echo 'Expected prepare or assert' >&2; exit 1 ;;
esac
