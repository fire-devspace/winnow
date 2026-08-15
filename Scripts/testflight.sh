#!/bin/bash
# btc-swift → TestFlight pipeline (App Store Connect API).
# Prereqs: archive IPA at build/BTCSwiftApp.ipa (see archive step below),
# API key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
#
#   export ASC_KEY_ID=5QT8WW3Q8H
#   export ASC_ISSUER_ID=<issuer uuid>   # ASC → Users and Access → Integrations
#   Scripts/testflight.sh all
#
# Steps (also runnable individually): register-bundle-id, create-app, upload,
# wait-processing, internal, external, all.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID}"
ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
BUNDLE_ID="com.btcswift.app"
APP_NAME="btc-swift"
API="https://api.appstoreconnect.apple.com/v1"

jwt() { DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Scripts/asc-jwt.swift "$KEY_PATH" "$KEY_ID" "$ISSUER"; }
asc() { # asc <METHOD> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -g -X "$method" -H "Authorization: Bearer $(jwt)" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "$API$path"
}

step_register_bundle_id() {
  asc GET "/bundleIds?filter[identifier]=$BUNDLE_ID" | tee /tmp/asc-bundleids.json
  if ! grep -q "$BUNDLE_ID" /tmp/asc-bundleids.json; then
    asc POST /bundleIds '{"data":{"type":"bundleIds","attributes":{"identifier":"'$BUNDLE_ID'","name":"btc-swift","platform":"IOS"}}}'
  fi
}

step_create_app() {
  local bid
  bid=$(asc GET "/bundleIds?filter[identifier]=$BUNDLE_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
  if asc GET "/apps?filter[bundleId]=$BUNDLE_ID" | grep -q "$BUNDLE_ID"; then
    echo "app record exists"; return
  fi
  asc POST /apps '{"data":{"type":"apps","attributes":{"name":"'$APP_NAME'","bundleId":"'$BUNDLE_ID'","sku":"btc-swift-ios","primaryLocale":"en-US"},"relationships":{"bundleId":{"data":{"type":"bundleIds","id":"'$bid'"}}}}}'
}

step_upload() {
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun altool --upload-app \
    -f build/BTCSwiftApp.ipa -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
}

app_id() { asc GET "/apps?filter[bundleId]=$BUNDLE_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'; }
build_id() { asc GET "/builds?filter[app]=$(app_id)&sort=-uploadedDate&limit=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'; }

step_wait_processing() {
  local id state
  id=$(build_id)
  for i in $(seq 1 60); do
    state=$(asc GET "/builds/$id" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]["attributes"]; print(d["processingState"])')
    echo "build $id: $state"
    [ "$state" = "VALID" ] && return 0
    [ "$state" = "FAILED" ] && return 1
    sleep 30
  done
  return 1
}

step_internal() {
  # Internal testing: the default "App Store Connect Users" group picks up the
  # processed build automatically once export compliance is set (handled via
  # Info.plist ITSAppUsesNonExemptEncryption=NO). Enable + notify:
  local id; id=$(build_id)
  asc GET "/builds/$id/betaGroups" >/dev/null
  asc PATCH "/builds/$id" '{"data":{"type":"builds","id":"'$id'","attributes":{"usesNonExemptEncryption":false}}}' || true
  echo "internal: build available to App Store Connect users"
}

step_external() {
  local aid bid gid
  aid=$(app_id); bid=$(build_id)
  gid=$(asc POST /betaGroups '{"data":{"type":"betaGroups","attributes":{"name":"Public","publicLinkEnabled":true},"relationships":{"app":{"data":{"type":"apps","id":"'$aid'"}}}}}' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')
  asc POST /betaGroups/"$gid"/relationships/builds '{"data":[{"type":"builds","id":"'$bid'"}]}'
  asc POST /betaTesters '{"data":{"type":"betaTesters","attributes":{}}}' 2>/dev/null || true # no-op placeholder
  # Beta details + review submission:
  asc GET "/builds/$bid/betaDetail" >/dev/null || true
  asc POST /betaAppReviewSubmissions '{"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":"'$bid'"}}}}}'
  echo "external: group Public created, build $bid submitted for beta review"
}

case "${1:-all}" in
  register-bundle-id) step_register_bundle_id ;;
  create-app) step_create_app ;;
  upload) step_upload ;;
  wait-processing) step_wait_processing ;;
  internal) step_internal ;;
  external) step_external ;;
  all) step_register_bundle_id; step_create_app; step_upload; step_wait_processing; step_internal; step_external ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
