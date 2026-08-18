#!/bin/bash
# Winnow → TestFlight pipeline (App Store Connect API).
# Prereqs: archive IPA at build/WinnowApp.ipa (see archive step below),
# API key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
#
#   export ASC_KEY_ID=5QT8WW3Q8H
#   export ASC_ISSUER_ID=<issuer uuid>   # ASC → Users and Access → Integrations
#   scripts/testflight.sh all
#
# Steps (also runnable individually): register-bundle-id, create-app, upload,
# wait-processing, notes, internal, external, status, all.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID}"
ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
BUNDLE_ID="com.btcswift.app"
APP_NAME="Winnow"
API="https://api.appstoreconnect.apple.com/v1"
PUBLIC_LINK_ID="${TESTFLIGHT_PUBLIC_LINK_ID:-83djpNE7}"
WHATS_NEW_FILE="${TESTFLIGHT_WHATS_NEW_FILE:-docs/testflight-what-to-test.txt}"
EXPECTED_BUILD_NUMBER="${TESTFLIGHT_BUILD_NUMBER:-}"
EXPECTED_MARKETING_VERSION="${TESTFLIGHT_MARKETING_VERSION:-}"

jwt() { DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/asc-jwt.swift "$KEY_PATH" "$KEY_ID" "$ISSUER"; }
asc() { # asc <METHOD> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(--fail-with-body -sS -g -X "$method" -H "Authorization: Bearer $(jwt)" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "$API$path"
}

step_register_bundle_id() {
  asc GET "/bundleIds?filter[identifier]=$BUNDLE_ID" | tee /tmp/asc-bundleids.json
  if ! grep -q "$BUNDLE_ID" /tmp/asc-bundleids.json; then
    asc POST /bundleIds '{"data":{"type":"bundleIds","attributes":{"identifier":"'$BUNDLE_ID'","name":"Winnow","platform":"IOS"}}}'
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
    -f build/WinnowApp.ipa -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
}

app_id() { asc GET "/apps?filter[bundleId]=$BUNDLE_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'; }
build_id() {
  if [ -n "${TESTFLIGHT_BUILD_ID:-}" ]; then
    printf '%s\n' "$TESTFLIGHT_BUILD_ID"
    return
  fi

  if [ -n "$EXPECTED_BUILD_NUMBER" ] && [ -n "$EXPECTED_MARKETING_VERSION" ]; then
    local aid response id
    aid=$(app_id)
    for attempt in $(seq 1 30); do
      response=$(asc GET "/builds?filter[app]=$aid&filter[version]=$EXPECTED_BUILD_NUMBER&filter[preReleaseVersion.version]=$EXPECTED_MARKETING_VERSION&limit=2")
      id=$(printf '%s' "$response" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
if len(rows) > 1:
    raise SystemExit(f"expected one matching build; found {len(rows)}")
print(rows[0]["id"] if rows else "")
')
      if [ -n "$id" ]; then
        printf '%s\n' "$id"
        return
      fi
      echo "waiting for uploaded version $EXPECTED_MARKETING_VERSION build $EXPECTED_BUILD_NUMBER to appear (attempt $attempt/30)" >&2
      sleep 10
    done
    echo "uploaded version $EXPECTED_MARKETING_VERSION build $EXPECTED_BUILD_NUMBER never appeared" >&2
    return 1
  fi

  asc GET "/builds?filter[app]=$(app_id)&sort=-uploadedDate&limit=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])'
}

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

step_notes() {
  local bid localizations localization_id payload response expected actual
  bid=$(build_id)
  if [ ! -s "$WHATS_NEW_FILE" ]; then
    echo "TestFlight What to Test file is missing or empty: $WHATS_NEW_FILE" >&2
    return 1
  fi

  localizations=$(asc GET "/builds/$bid/betaBuildLocalizations?limit=200")
  localization_id=$(printf '%s' "$localizations" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
matches = [row for row in rows if row.get("attributes", {}).get("locale") == "en-US"]
if len(matches) > 1:
    raise SystemExit(f"expected at most one en-US localization; found {len(matches)}")
print(matches[0]["id"] if matches else "")
')

  if [ -n "$localization_id" ]; then
    payload=$(python3 -c '
import json, pathlib, sys
path, resource_id = sys.argv[1:]
print(json.dumps({"data": {"type": "betaBuildLocalizations", "id": resource_id,
                           "attributes": {"whatsNew": pathlib.Path(path).read_text().rstrip()}}}))
' "$WHATS_NEW_FILE" "$localization_id")
    response=$(asc PATCH "/betaBuildLocalizations/$localization_id" "$payload")
    echo "notes: updated en-US What to Test for build $bid"
  else
    payload=$(python3 -c '
import json, pathlib, sys
path, build_id = sys.argv[1:]
print(json.dumps({"data": {"type": "betaBuildLocalizations",
                           "attributes": {"locale": "en-US", "whatsNew": pathlib.Path(path).read_text().rstrip()},
                           "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}}))
' "$WHATS_NEW_FILE" "$bid")
    response=$(asc POST /betaBuildLocalizations "$payload")
    echo "notes: created en-US What to Test for build $bid"
  fi

  expected=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().rstrip())' "$WHATS_NEW_FILE")
  actual=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"]["whatsNew"])')
  if [ "$actual" != "$expected" ]; then
    echo "notes: App Store Connect did not return the requested What to Test text" >&2
    return 1
  fi
}

step_internal() {
  # Internal testing: the default "App Store Connect Users" group picks up the
  # processed build automatically. Export compliance is declared in Info.plist;
  # verify Apple's state instead of issuing a PATCH that returns 409 once set.
  local id detail state
  id=$(build_id)
  detail=$(asc GET "/builds/$id/buildBetaDetail")
  state=$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"]["internalBuildState"])')
  case "$state" in
    READY_FOR_BETA_TESTING|IN_BETA_TESTING)
      echo "internal: build $id is $state"
      ;;
    *)
      echo "internal: build $id is not testable ($state)" >&2
      return 1
      ;;
  esac
}

public_group_id() {
  local aid groups
  aid=$(app_id)
  groups=$(asc GET "/betaGroups?filter[app]=$aid&filter[publicLinkEnabled]=true&limit=200&fields[betaGroups]=name,publicLink,publicLinkId,isInternalGroup,publicLinkEnabled,createdDate")
  printf '%s' "$groups" | python3 -c '
import json, sys
expected = sys.argv[1]
groups = json.load(sys.stdin)["data"]
matches = [g for g in groups if (
    g.get("attributes", {}).get("publicLinkId") == expected
    or g.get("attributes", {}).get("publicLink", "").rstrip("/").endswith("/" + expected)
)]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one public beta group for link {expected}; found {len(matches)}")
print(matches[0]["id"])
' "$PUBLIC_LINK_ID"
}

review_state() {
  local bid="$1"
  asc GET "/betaAppReviewSubmissions?filter[build]=$bid&limit=1" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["data"]
print(rows[0]["attributes"]["betaReviewState"] if rows else "NOT_SUBMITTED")
'
}

build_in_group() {
  local bid="$1" gid="$2"
  asc GET "/builds?filter[app]=$(app_id)&filter[betaGroups]=$gid&filter[id]=$bid&limit=1" | python3 -c '
import json, sys
raise SystemExit(0 if json.load(sys.stdin)["data"] else 1)
'
}

step_external() {
  local bid gid state
  bid=$(build_id)
  gid=$(public_group_id)

  if build_in_group "$bid" "$gid"; then
    echo "external: build $bid already belongs to public link $PUBLIC_LINK_ID"
  else
    asc POST "/betaGroups/$gid/relationships/builds" \
      '{"data":[{"type":"builds","id":"'$bid'"}]}' >/dev/null
    echo "external: added build $bid to public link $PUBLIC_LINK_ID"
  fi

  state=$(review_state "$bid")
  case "$state" in
    WAITING_FOR_REVIEW|IN_REVIEW|APPROVED)
      echo "external: build $bid review state is $state"
      return 0
      ;;
    REJECTED)
      echo "external: build $bid was rejected by beta review" >&2
      return 1
      ;;
  esac

  # App Store Connect can report a build VALID a few seconds before its beta
  # quality-control state accepts a review submission. Retry that short race,
  # but surface any lasting API error instead of printing a false success.
  for attempt in $(seq 1 12); do
    if asc POST /betaAppReviewSubmissions \
      '{"data":{"type":"betaAppReviewSubmissions","relationships":{"build":{"data":{"type":"builds","id":"'$bid'"}}}}}' >/dev/null; then
      state=$(review_state "$bid")
      echo "external: build $bid review state is $state"
      [ "$state" != "NOT_SUBMITTED" ]
      return
    fi
    echo "external: review submission not ready (attempt $attempt/12); retrying" >&2
    sleep 15
  done

  echo "external: Apple did not accept beta review submission for build $bid" >&2
  return 1
}

step_status() {
  local bid gid processing internal external review grouped
  bid=$(build_id)
  gid=$(public_group_id)
  processing=$(asc GET "/builds/$bid" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["attributes"]["processingState"])')
  read -r internal external < <(asc GET "/builds/$bid/buildBetaDetail" | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["attributes"]
print(a["internalBuildState"], a["externalBuildState"])
')
  review=$(review_state "$bid")
  grouped=no
  build_in_group "$bid" "$gid" && grouped=yes
  printf 'build=%s processing=%s internal=%s external=%s review=%s public_link=%s grouped=%s\n' \
    "$bid" "$processing" "$internal" "$external" "$review" "$PUBLIC_LINK_ID" "$grouped"

  [ "$processing" = "VALID" ]
  [ "$grouped" = "yes" ]
  case "$internal" in READY_FOR_BETA_TESTING|IN_BETA_TESTING) ;; *) return 1 ;; esac
  case "$review" in WAITING_FOR_REVIEW|IN_REVIEW|APPROVED) ;; *) return 1 ;; esac
}

case "${1:-all}" in
  register-bundle-id) step_register_bundle_id ;;
  create-app) step_create_app ;;
  upload) step_upload ;;
  wait-processing) step_wait_processing ;;
  notes) step_notes ;;
  internal) step_internal ;;
  external) step_external ;;
  status) step_status ;;
  all) step_register_bundle_id; step_create_app; step_upload; step_wait_processing; step_notes; step_internal; step_external ;;
  *) echo "unknown step $1" >&2; exit 2 ;;
esac
