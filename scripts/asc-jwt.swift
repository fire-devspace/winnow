#!/usr/bin/env swift
// Mints an App Store Connect API JWT (ES256) from an AuthKey .p8 file.
// Usage: swift scripts/asc-jwt.swift <keyPath> <keyId> <issuerId>
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: asc-jwt.swift <keyPath> <keyId> <issuerId>\n".data(using: .utf8)!)
    exit(2)
}
let (keyPath, keyId, issuer) = (args[1], args[2], args[3])

func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
let key = try P256.Signing.PrivateKey(pemRepresentation: pem)

let header = b64url(try JSONSerialization.data(withJSONObject: [
    "alg": "ES256", "kid": keyId, "typ": "JWT",
]))
let now = Int(Date().timeIntervalSince1970)
let payload = b64url(try JSONSerialization.data(withJSONObject: [
    "iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1",
]))
let signingInput = "\(header).\(payload)"
let sig = try key.signature(for: Data(signingInput.utf8))
print("\(signingInput).\(b64url(sig.rawRepresentation))")
