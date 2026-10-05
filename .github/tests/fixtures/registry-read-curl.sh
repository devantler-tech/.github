#!/usr/bin/env bash
# Exact read-only Registry V2 requests; uploads and unrelated URLs fail closed.
set -euo pipefail
[[ "$#" == 24 || "$#" == 21 ]] || exit 90
[[ "$1" == -q && "$2" == --silent && "$3" == --show-error && "$4" == --proto && "$5" == '=https' &&
   "$6" == --tlsv1.2 && "$7" == --connect-timeout && "$8" == 10 && "$9" == --max-time &&
   "${10}" == 30 && "${11}" == --max-filesize && "${12}" == 1048576 && "${13}" == --output &&
   "${15}" == --write-out && "${16}" == '%{http_code}' ]] || exit 91
output="${14}"
if [[ "$#" == 24 ]]; then
  [[ "${17}" == --get && "${18}" == --data-urlencode && "${19}" == "service=$REGISTRY" &&
     "${20}" == --data-urlencode && "${21}" == scope=repository:*:pull &&
     "${22}" == --user && "${23}" == "$ACTOR:$GH_TOKEN" && "${24}" == "https://$REGISTRY/token" ]] || exit 92
  printf '{"token":"synthetic-bearer"}' >"$output"
  printf 200
else
  [[ "${17}" == --header && "${18}" == 'Authorization: Bearer synthetic-bearer' &&
     "${19}" == --header && "${20}" == 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' &&
     "${21}" == "https://$REGISTRY/v2/"*"/manifests/$VERSION" ]] || exit 93
  scenario="${FAULT:-${FAIL_AT:-none}}"
  if [[ "$scenario" == registry-existing ||
        ( "$scenario" == registry-image-only && "${21}" != */manifests/manifests/* ) ||
        ( "$scenario" == registry-manifests-only && "${21}" == */manifests/manifests/* ) ||
        ( "$scenario" == registry-raced && ( -e "$STATE/verified" ||
          ( "${SIGNED_PROMOTION:-true}" == false && -e "$STATE/signed" ) ) ) ]]; then
    printf '{}' >"$output"; printf 200
  else
    printf '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' >"$output"; printf 404
  fi
fi
