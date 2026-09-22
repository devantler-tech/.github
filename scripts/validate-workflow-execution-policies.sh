#!/usr/bin/env bash
# validate-workflow-execution-policies.sh — check the reviewed workflow execution policy files.
#
# Usage:
#   validate-workflow-execution-policies.sh [<policies-dir>]   # default: workflow-execution-policies/
#
# Each *.json file is one organization policy in the request shape of
# POST /orgs/{org}/actions/policies. The files are desired state only: nothing here applies them.
# The check fails when a file:
#   - is not a JSON object, or its name is not a non-empty string
#   - has a top-level key or condition the API does not define (a mistyped optional field would
#     otherwise be dropped silently)
#   - uses an enforcement other than evaluate or disabled (active needs maintainer approval)
#   - has no rules, or a rule type the API does not define
#   - names an actor without an integer id, or with a type the API does not define
#   - allows an event the API does not define
#   - allows pull_request_target or workflow_run without an "exception" object that names the
#     workflow paths it covers (non-empty strings) and a "threat_model" explaining why they are
#     safe, or whose workflow_path include targets anything the exception does not list (~ALL
#     or an unlisted path): the exception is stripped before sending, so only this binds it
#   - does not target repositories by exactly one of repository_name, repository_id or
#     repository_property (an organization policy must name its repositories)
#   - gives a condition the wrong shape: repository_name or repository_property without an
#     include array, repository_id without integer repository_ids, or workflow_path without both
#     include and exclude arrays
#   - gives those arrays the wrong members: repository_name or workflow_path patterns that are
#     not non-empty strings, repository_property members without a name and non-empty string
#     property_values, or a workflow_path with no include or exclude pattern at all
#   - mixes ~ALL into other workflow_path include patterns, or puts ~ALL in workflow_path exclude
#   - names specific workflow_path files without targeting exactly one repository by exact name
#     (a file name can mean a different workflow in each repository)
# The exception object is this repository's own review record. Strip it before sending a file to
# the API.
#
# Exit codes: 0 every file passes · 1 at least one file fails · 2 invalid usage or no files.
set -euo pipefail

dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workflow-execution-policies}"
[ -d "$dir" ] || { echo "validate-workflow-execution-policies: no directory $dir" >&2; exit 2; }

shopt -s nullglob
files=("$dir"/*.json)
[ "${#files[@]}" -gt 0 ] || { echo "validate-workflow-execution-policies: no policy files in $dir" >&2; exit 2; }

# The values GET/POST /orgs/{org}/actions/policies accepts (REST API, 2026-09-17 GA).
events='["branch_protection_rule","check_run","check_suite","create","delete","deployment",
  "deployment_status","discussion","discussion_comment","fork","gollum","image_version",
  "issue_comment","issues","label","merge_group","milestone","page_build","project","project_card",
  "project_column","public","pull_request","pull_request_review","pull_request_review_comment",
  "pull_request_target","push","registry_package","release","repository_dispatch","schedule",
  "status","watch","workflow_call","workflow_dispatch","workflow_run"]'
actor_types='["User","Bot","Team","BusinessTeam","EnterpriseTeam","IntegrationInstallation","App",
  "RepositoryRole"]'

failed=0
for f in "${files[@]}"; do
  # One problem per line; an empty result means the file passes.
  problems="$(jq -r --argjson events "$events" --argjson actor_types "$actor_types" '
    def privileged: ["pull_request_target", "workflow_run"];
    if type != "object" then "not a JSON object" else
      ( if (.name | type) != "string" or .name == "" then "name must be a non-empty string" else empty end ),
      ( keys[] | select(IN("name", "enforcement", "conditions", "rules", "exception") | not)
        | "unknown key \(tojson); only name, enforcement, conditions, rules and exception are allowed" ),
      ( if (.enforcement | IN("evaluate", "disabled")) | not
        then "enforcement \(.enforcement | tojson) is not evaluate or disabled; active needs maintainer approval"
        else empty end ),
      ( if (.rules | type) != "array" or (.rules | length) == 0 then "rules must be a non-empty array"
        else
          ( .rules[]
            | if .type == "restrict_actions_actors" then
                ( if (.parameters.allowed_actors | type) != "array" or (.parameters.allowed_actors | length) == 0
                  then "restrict_actions_actors needs a non-empty allowed_actors array" else empty end ),
                ( .parameters.allowed_actors[]?
                  | ( if (.id | type) != "number" or (.id | floor) != .id then "actor id \(.id | tojson) is not an integer" else empty end ),
                    ( if (.type | IN($actor_types[])) | not then "actor type \(.type | tojson) is not defined by the API" else empty end ) )
              elif .type == "restrict_action_events" then
                ( if (.parameters.allowed_events | type) != "array" or (.parameters.allowed_events | length) == 0
                  then "restrict_action_events needs a non-empty allowed_events array" else empty end ),
                ( .parameters.allowed_events[]? | select(IN($events[]) | not) | "event \(tojson) is not defined by the API" )
              else "rule type \(.type | tojson) is not defined by the API" end )
        end ),
      ( [ .rules[]? | select(.type == "restrict_action_events") | .parameters.allowed_events[]? | select(IN(privileged[])) ] as $p
        | if ($p | length) == 0 then empty
          elif (.exception.workflow_paths | type) != "array" or (.exception.workflow_paths | length) == 0
              or any(.exception.workflow_paths[]; type != "string" or . == "")
              or (.exception.threat_model | type) != "string" or .exception.threat_model == ""
          then "allows \($p | unique | join(", ")) without an exception naming its workflow_paths and threat_model"
          # The exception is stripped before the API sees it, so only this check ties it to the
          # policy: the policy may target nothing beyond the paths the exception lists.
          elif (.conditions.workflow_path.include | type) != "array" or (.conditions.workflow_path.include | length) == 0
              or (.exception.workflow_paths as $ex | any(.conditions.workflow_path.include[]; . == "~ALL" or (IN($ex[]) | not)))
          then "allows \($p | unique | join(", ")) but targets workflow paths the exception does not list"
          else empty end ),
      ( if (.conditions | type) != "object" then "conditions must be an object" else
          ( .conditions | keys[]
            | select(IN("repository_name", "repository_id", "repository_property", "workflow_path") | not)
            | "unknown condition \(tojson); only repository_name, repository_id, repository_property and workflow_path are allowed" ),
          ( [ .conditions | keys[] | select(IN("repository_name", "repository_id", "repository_property")) ] | length
            | if . != 1 then "conditions must target repositories by exactly one of repository_name, repository_id or repository_property" else empty end ),
          ( if .conditions | has("repository_name") and ((.repository_name | type) != "object" or (.repository_name.include | type) != "array")
            then "repository_name must be an object with an include array" else empty end ),
          ( if .conditions | has("repository_id") and ((.repository_id | type) != "object" or (.repository_id.repository_ids | type) != "array"
                or any(.repository_id.repository_ids[]; type != "number" or floor != .))
            then "repository_id must be an object with an integer repository_ids array" else empty end ),
          ( if .conditions | has("repository_property") and ((.repository_property | type) != "object" or (.repository_property.include | type) != "array")
            then "repository_property must be an object with an include array" else empty end ),
          ( if .conditions | has("workflow_path") and ((.workflow_path | type) != "object"
                or (.workflow_path.include | type) != "array" or (.workflow_path.exclude | type) != "array")
            then "workflow_path must be an object with include and exclude arrays" else empty end ),
          ( if .conditions.repository_name | type == "object" and
                any((.include, .exclude) | arrays | .[]; type != "string" or . == "")
            then "repository_name include and exclude must hold non-empty strings" else empty end ),
          ( if .conditions.repository_property | type == "object" and
                any((.include, .exclude) | arrays | .[];
                  type != "object" or (.name | type) != "string" or .name == ""
                  or (.property_values | type) != "array" or (.property_values | length) == 0
                  or any(.property_values[]; type != "string"))
            then "repository_property include members need a name and non-empty property_values" else empty end ),
          ( if .conditions.workflow_path | type == "object" and
                any((.include, .exclude) | arrays | .[]; type != "string" or . == "")
            then "workflow_path include and exclude must hold non-empty strings" else empty end ),
          ( if .conditions.workflow_path | type == "object" and (.include | type) == "array" and (.exclude | type) == "array"
                and (.include | length) + (.exclude | length) == 0
            then "workflow_path needs at least one include or exclude pattern" else empty end )
        end ),
      ( (.conditions.workflow_path.include // []) as $inc
        | if ($inc | index("~ALL")) != null and ($inc | length) > 1
          then "workflow_path include mixes ~ALL with other patterns" else empty end ),
      ( if (.conditions.workflow_path.exclude // [] | index("~ALL")) != null
        then "workflow_path exclude may not contain ~ALL" else empty end ),
      # A file name means a different workflow in each repository (ci.yaml deploys in one and
      # only tests in another), so naming files is only reviewable against a single repository.
      ( (.conditions.workflow_path.include // []) as $inc
        | if ($inc | length) > 0 and ($inc | index("~ALL")) == null
            and ((.conditions.repository_name.include // null) as $r
              | ($r | type) != "array" or ($r | length) != 1
                or ($r[0] | type) != "string" or ($r[0] | test("^~ALL$|[*?\\[]")))
          then "workflow_path names specific files, so repository_name must include exactly one repository by exact name"
          else empty end )
    end' "$f" 2>/dev/null)" || problems="not valid JSON"
  if [ -n "$problems" ]; then
    failed=1
    while IFS= read -r p; do echo "FAIL ${f##*/}: $p"; done <<<"$problems"
  else
    echo "OK   ${f##*/}"
  fi
done
exit "$failed"
