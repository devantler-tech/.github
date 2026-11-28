#!/usr/bin/env bash
# Shared authenticated installation and complete repository-page proof.
# Callers own a private work directory, abort handler and explicit completion latch.
work="${work:?private census directory required}"
mode="${mode:?census mode required}"
capture() {
  gh api --method GET --paginate --slurp "$1" >"$2" 2>"$work/api-error" || abort
}
installation_proof() {
  # The token comes from the GitHub token broker (devantler-tech/monorepo ADR 0020) under an
  # unscoped organization policy, which the boundary tests pin, so it sees every repository its
  # installation can. The broker may issue it from either App, so both installations must cover
  # all repositories: the organization's installation list (organization administration read)
  # is the documented place that states each installation's repository selection.
  gh api --method GET --paginate --slurp 'orgs/devantler-tech/installations?per_page=100' \
    >"$work/installation.json" 2>"$work/api-error" || abort
  jq -e -s 'length == 1 and (.[0] | type == "array" and length > 0 and
    all(type == "object" and (.installations | type == "array"))) and
    ([.[0][].installations[] | select(.app_slug == "botantler-1" or .app_slug == "botantler-2")] as $apps |
      ($apps | length == 2) and ($apps | map(.app_slug) | sort == ["botantler-1", "botantler-2"]) and
      ($apps | all(.repository_selection == "all" and .target_type == "Organization" and
        .account.login == "devantler-tech" and .account.type == "Organization" and
        (.account.id | type == "number" and . > 0 and . == floor) and .target_id == .account.id and
        has("suspended_at") and .suspended_at == null)) and
      ($apps | map(.account.id) | unique | length == 1))' \
    "$work/installation.json" >/dev/null 2>"$work/parse-error" || abort
  org_id="$(jq -r -s '[.[0][].installations[] | select(.app_slug == "botantler-1")][0].account.id' "$work/installation.json")"
  jq -S -s '[.[0][].installations[] | select(.app_slug == "botantler-1" or .app_slug == "botantler-2") |
    {id, app_id, app_slug, target_id, target_type, account: {id: .account.id, login: .account.login, type: .account.type},
      repository_selection, suspended_at}] | sort_by(.app_slug)' \
    "$work/installation.json" >"$work/installation.canonical" 2>"$work/parse-error" || abort
}
prepare_installation_proof() {
  # Only the reviewed main workflow supplies an unrestricted, read-only installation
  # token. An arbitrary caller token cannot establish complete installation visibility.
  [[ "${GITHUB_ACTIONS:-}" == true &&
    "${GITHUB_REPOSITORY:-}" == devantler-tech/.github &&
    "${GITHUB_REF:-}" == refs/heads/main &&
    -n "${GH_TOKEN:-}" ]] || abort
  case "${GITHUB_WORKFLOW_REF:-}" in
  devantler-tech/.github/.github/workflows/repository-admin-team-audit.yaml@refs/heads/main)
    [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] || abort
    ;;
  devantler-tech/.github/.github/workflows/governance-audits.yaml@refs/heads/main | \
    devantler-tech/.github/.github/workflows/repository-coverage-check.yaml@refs/heads/main)
    [[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch || "${GITHUB_EVENT_NAME:-}" == schedule ]] || abort
    ;;
  *) abort ;;
  esac
  installation_proof
  cp "$work/installation.canonical" "$work/installation-before.canonical"
}
validate_repositories() {
  jq -e -s --arg mode "$mode" --argjson public "${public_count:-0}" --argjson private "${private_count:-0}" --argjson org_id "${org_id:-0}" '
    length == 1 and (.[0] as $pages |
      ($pages | type == "array" and length > 0) and
      (if $mode == "installation" then
        ($pages | all(type == "object" and
          (.total_count | type == "number" and . > 0 and . == floor) and
          (.repositories | type == "array" and length <= 100))) and
        ($pages | map(.total_count) | unique | length == 1)
       else ($pages | all(type == "array" and length <= 100)) end) and
      ((if $mode == "installation" then [$pages[].repositories[]] else [$pages[][]] end) as $repos |
        (if $mode == "installation" then ($repos | length == $pages[0].total_count)
         else ($repos | length == ($public + $private)) and
           ([$repos[] | select(.private == false)] | length == $public) and
           ([$repos[] | select(.private == true)] | length == $private) end) and
        ($repos | map(.id) | unique | length == ($repos | length)) and
        ($repos | map(.name) | unique | length == ($repos | length)) and
        ($repos | map(.owner.id) | unique | length == 1) and
        ($repos | all(type == "object" and
          (.id | type == "number" and . > 0 and . == floor) and
          (.name | type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..") and
          .owner.login == "devantler-tech" and
          (.owner.id | type == "number" and . > 0 and . == floor) and
          .owner.id == $org_id and
          .full_name == ("devantler-tech/" + .name) and
          (.archived | type == "boolean") and (.private | type == "boolean")))))
  ' "$1" >/dev/null 2>"$work/parse-error" || abort
}
