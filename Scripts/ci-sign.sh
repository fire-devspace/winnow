#!/bin/bash
# CI signing setup: mint an Apple Distribution certificate via the App Store
# Connect API and install it into a temporary keychain for xcodebuild.
# Needs env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (PEM contents).
set -euo pipefail

KEYCHAIN="btc-swift-ci.keychain-db"
KEYCHAIN_PASSWORD="ci-$(date +%s)"
WORK="${RUNNER_TEMP:-/tmp}/btc-swift-signing"
mkdir -p "$WORK"

echo "$ASC_PRIVATE_KEY" > "$WORK/AuthKey.p8"

# Keychain
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# CSR -> ASC API -> certificate
openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/dist.key" \
  -out "$WORK/dist.csr" -subj "/CN=btc-swift-ci" 2>/dev/null
JWT=$(swift "$(dirname "$0")/asc-jwt.swift" "$WORK/AuthKey.p8" "$ASC_KEY_ID" "$ASC_ISSUER_ID")
echo "JWT minted (length ${#JWT})"
export WORK
BODY=$(python3 - <<'PYEOF'
import json, os
with open(os.path.join(os.environ["WORK"], "dist.csr")) as f:
    csr = f.read()
print(json.dumps({"data": {"type": "certificates", "attributes": {
    "certificateType": "IOS_DISTRIBUTION", "csrContent": csr}}}))
PYEOF
)
RESPONSE=$(curl -sS -g -X POST -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d "$BODY" \
  -o "$WORK/cert-response.json" \
  -w '%{http_code}' \
  https://api.appstoreconnect.apple.com/v1/certificates)
echo "certificates POST: HTTP $RESPONSE; body bytes: $(wc -c < "$WORK/cert-response.json")"
python3 - "$WORK/cert-response.json" <<'PYEOF'
import json, os, sys, textwrap
with open(sys.argv[1]) as f:
    d = json.load(f)
if "errors" in d:
    print(d["errors"][0].get("detail"), file=sys.stderr)
    sys.exit(1)
# ASC API returns bare base64 DER without PEM armor — wrap it.
body = d["data"]["attributes"]["certificateContent"]
pem = "-----BEGIN CERTIFICATE-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END CERTIFICATE-----\n"
with open(os.path.join(os.environ["WORK"], "dist.cer"), "w") as f:
    f.write(pem)
PYEOF
openssl x509 -inform PEM -in "$WORK/dist.cer" -outform PEM -out "$WORK/dist.pem"
openssl pkcs12 -export -inkey "$WORK/dist.key" -in "$WORK/dist.pem" \
  -out "$WORK/dist.p12" -passout pass:"$KEYCHAIN_PASSWORD" -name "btc-swift-ci"
security import "$WORK/dist.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" \
  -T /usr/bin/codesign -T xcodebuild
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
echo "signing identity installed in $KEYCHAIN"
