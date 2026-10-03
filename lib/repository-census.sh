#!/usr/bin/env bash
# Shared authenticated installation and complete repository-page proof.
# Callers own a private work directory, abort handler and explicit completion latch.
work="${work:?private census directory required}"
mode="${mode:?census mode required}"
capture() {
  gh api --method GET --paginate --slurp "$1" >"$2" 2>"$work/api-error" || abort
}
installation_proof() {
  curl --disable --silent --show-error --fail --request GET --max-time 30 --proto '=https' \
    --config "$work/app-request.conf" --url "https://api.github.com/app/installations/$installation_id" \
    --output "$work/installation.json" 2>"$work/api-error" || abort
  jq -e -s --argjson id "$installation_id" 'length == 1 and (.[0] |
    type == "object" and .id == $id and
    (.app_id | type == "number" and . > 0 and . == floor) and
    .repository_selection == "all" and .target_type == "Organization" and
    .account.type == "Organization" and .account.login == "devantler-tech" and
    (.account.id | type == "number" and . > 0 and . == floor) and .target_id == .account.id and
    has("suspended_at") and .suspended_at == null and has("suspended_by") and .suspended_by == null)' \
    "$work/installation.json" >/dev/null 2>"$work/parse-error" || abort
  org_id="$(jq -r '.account.id' "$work/installation.json")"
  jq -S '{id,app_id,target_id,target_type,account:{id:.account.id,login:.account.login,type:.account.type},repository_selection,suspended_at,suspended_by}' \
    "$work/installation.json" >"$work/installation.canonical" 2>"$work/parse-error" || abort
}
prepare_installation_proof() {
  # Only the reviewed main workflow supplies an unrestricted, read-only installation
  # token. An arbitrary caller token cannot establish complete installation visibility.
  [[ "${GITHUB_ACTIONS:-}" == true &&
    "${GITHUB_REPOSITORY:-}" == devantler-tech/.github &&
    "${GITHUB_REF:-}" == refs/heads/main &&
    -n "${GH_TOKEN:-}" && -n "${GH_APP_PRIVATE_KEY:-}" &&
    "${GH_APP_CLIENT_ID:-}" =~ ^(Iv[0-9A-Za-z._-]+|[0-9]+)$ &&
    "${GH_INSTALLATION_ID:-}" =~ ^[1-9][0-9]*$ ]] || abort
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
  command -v openssl >/dev/null || abort
  command -v curl >/dev/null || abort
  installation_id="$GH_INSTALLATION_ID"
  printf '%s' "$GH_APP_PRIVATE_KEY" >"$work/app-key.pem"
  unset GH_APP_PRIVATE_KEY
  local now header payload signature jwt
  now="$(date +%s)"
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  payload=$(jq -cn --arg iss "$GH_APP_CLIENT_ID" --argjson iat "$((now - 60))" --argjson exp "$((now + 540))" \
    '{iss:$iss,iat:$iat,exp:$exp}' | openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  signature=$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$work/app-key.pem" 2>"$work/parse-error" |
    openssl base64 -A | tr '+/' '-_' | tr -d '=') || abort
  rm "$work/app-key.pem"
  jwt="$header.$payload.$signature"
  printf '::add-mask::%s\n' "$jwt"
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2026-03-10"\n' \
    "$jwt" >"$work/app-request.conf"
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
