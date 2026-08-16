import CryptoKit
import Foundation
import P256K
import Testing
@testable import BitcoinCore

/// BIP352 silent payments, receive side: the official receiving vectors from
/// bip-0352/send_and_receive_test_vectors.json (the same vendored file the
/// sending tests use — each case carries both sides), plus a derivation-path
/// pin. The vendored file is enriched with the intermediate `tweak`
/// (input_hash·A — exactly what a tweak index serves), `shared_secret`, and
/// `input_pub_key_sum` fields, asserted here so a scan failure localizes.
@Suite("BIP352 silent payment receiving")
struct SilentPaymentReceiveTests {
    struct Vin {
        let txid: Data // internal byte order
        let vout: UInt32
        let scriptSig: Data
        let witness: [Data]
        let prevoutScript: Data

        /// COutPoint serialization, the order outpoints are compared in.
        var outpoint: Data {
            var littleEndianVout = vout.littleEndian
            return txid + withUnsafeBytes(of: &littleEndianVout) { Data($0) }
        }
    }

    struct ExpectedOutput {
        let privateKeyTweak: Data
        let publicKey: Data // 32-byte x-only
        let signature: Data
    }

    struct ReceivingCase {
        let comment: String
        let vins: [Vin]
        let txOutputs: [Data] // x-only taproot output keys of the tx
        let scanPrivateKey: Data
        let spendPrivateKey: Data
        let labels: [UInt32]
        let expectedAddresses: [String]
        let expectedOutputs: [ExpectedOutput] // empty when only a count is given
        let expectedCount: Int
        let expectedKeySum: Data? // absent when the receiver skips the tx
        let expectedTweakData: Data?
        let expectedSharedSecret: Data?
    }

    static func receivingCases() throws -> [ReceivingCase] {
        let json = try JSONSerialization.jsonObject(
            with: vectorData("bip352-send-receive-vectors.json")) as! [[String: Any]]
        return try json.flatMap { entry -> [ReceivingCase] in
            let comment = entry["comment"] as! String
            return try (entry["receiving"] as! [[String: Any]]).map { receiving in
                let given = receiving["given"] as! [String: Any]
                let expected = receiving["expected"] as! [String: Any]
                let vins = try (given["vin"] as! [[String: Any]]).map { vin -> Vin in
                    let scriptSigHex = vin["scriptSig"] as! String
                    guard let txid = Data(hex: vin["txid"] as! String),
                          let prevout = vin["prevout"] as? [String: Any],
                          let spk = prevout["scriptPubKey"] as? [String: Any],
                          let script = Data(hex: spk["hex"] as! String),
                          let scriptSig = scriptSigHex.isEmpty ? Data() : Data(hex: scriptSigHex)
                    else { throw VectorError.badHex(comment) }
                    // JSON txids are display (big-endian) order.
                    return Vin(txid: Data(txid.reversed()), vout: vin["vout"] as! UInt32,
                               scriptSig: scriptSig,
                               witness: try SilentPaymentTests.witnessStack(
                                   from: vin["txinwitness"] as! String),
                               prevoutScript: script)
                }
                let keyMaterial = given["key_material"] as! [String: String]
                let outputs = try (expected["outputs"] as? [[String: String]] ?? []).map { output in
                    guard let tweak = Data(hex: output["priv_key_tweak"]!),
                          let publicKey = Data(hex: output["pub_key"]!),
                          let signature = Data(hex: output["signature"]!)
                    else { throw VectorError.badHex(comment) }
                    return ExpectedOutput(privateKeyTweak: tweak, publicKey: publicKey,
                                          signature: signature)
                }
                guard let txOutputs = try? (given["outputs"] as! [String]).map({
                    guard let key = Data(hex: $0) else { throw VectorError.badHex(comment) }
                    return key
                }), let scanPrivateKey = Data(hex: keyMaterial["scan_priv_key"]!),
                    let spendPrivateKey = Data(hex: keyMaterial["spend_priv_key"]!)
                else { throw VectorError.badHex(comment) }
                return ReceivingCase(
                    comment: comment, vins: vins, txOutputs: txOutputs,
                    scanPrivateKey: scanPrivateKey, spendPrivateKey: spendPrivateKey,
                    labels: (given["labels"] as! [Int]).map { UInt32($0) },
                    expectedAddresses: expected["addresses"] as! [String],
                    expectedOutputs: outputs,
                    expectedCount: expected["n_outputs"] as? Int ?? outputs.count,
                    expectedKeySum: (expected["input_pub_key_sum"] as? String).flatMap { Data(hex: $0) },
                    expectedTweakData: (expected["tweak"] as? String).flatMap { Data(hex: $0) },
                    expectedSharedSecret: (expected["shared_secret"] as? String).flatMap { Data(hex: $0) })
            }
        }
    }

    /// The eligible input public keys of a vectors transaction, via the
    /// key-free extraction the scanner uses.
    static func eligibleKeys(of vins: [Vin]) -> [Data] {
        vins.compactMap {
            SilentPaymentSending.eligiblePublicKey(prevoutScriptPubKey: $0.prevoutScript,
                                                   scriptSig: $0.scriptSig, witness: $0.witness)
        }
    }

    /// Tweak data recomputed from the raw transaction — nil when the receiver
    /// skips it (no eligible inputs, or A at infinity). Production sources
    /// this from a tweak index instead; the math must agree.
    static func tweakData(of vins: [Vin]) throws -> Data? {
        guard let sum = try SilentPaymentReceiving.inputPublicKeySum(eligibleKeys(of: vins)) else {
            return nil
        }
        let smallestOutpoint = vins.map(\.outpoint)
            .min(by: { $0.lexicographicallyPrecedes($1) }) ?? Data()
        return try SilentPaymentReceiving.tweakData(inputPublicKeySum: sum,
                                                    smallestOutpoint: smallestOutpoint)
    }

    @Test func addressesMatchVectors() throws {
        for testCase in try Self.receivingCases() {
            let spendPublicKey = try SilentPaymentSending.publicKeyPoint(testCase.spendPrivateKey)
            // The vectors list the plain address first, then one per label in
            // the order the receiver created them.
            var addresses = [try SilentPaymentReceiving.address(
                scanPrivateKey: testCase.scanPrivateKey, spendPublicKey: spendPublicKey,
                hrp: "sp").encoded]
            for label in testCase.labels {
                addresses.append(try SilentPaymentReceiving.address(
                    scanPrivateKey: testCase.scanPrivateKey, spendPublicKey: spendPublicKey,
                    label: label, hrp: "sp").encoded)
            }
            #expect(addresses == testCase.expectedAddresses, Comment(rawValue: testCase.comment))
        }
    }

    @Test func tweakDataMatchesVectors() throws {
        for testCase in try Self.receivingCases() {
            let sum = try SilentPaymentReceiving.inputPublicKeySum(Self.eligibleKeys(of: testCase.vins))
            #expect(sum == testCase.expectedKeySum, Comment(rawValue: testCase.comment))
            let tweakData = try Self.tweakData(of: testCase.vins)
            #expect(tweakData == testCase.expectedTweakData, Comment(rawValue: testCase.comment))
        }
    }

    @Test func scanRecoversVectorOutputs() throws {
        for testCase in try Self.receivingCases() {
            let comment = Comment(rawValue: testCase.comment)
            guard let tweakData = try Self.tweakData(of: testCase.vins) else {
                // Receiver skips the transaction entirely (BIP352: no eligible
                // inputs / A at infinity) — nothing may be expected of it.
                #expect(testCase.expectedCount == 0, comment)
                continue
            }
            let sharedSecret = try SilentPaymentReceiving.sharedSecret(
                scanPrivateKey: testCase.scanPrivateKey, tweakData: tweakData)
            #expect(sharedSecret == testCase.expectedSharedSecret, comment)

            let spendPublicKey = try SilentPaymentSending.publicKeyPoint(testCase.spendPrivateKey)
            let matches = try SilentPaymentReceiving.scan(
                outputs: testCase.txOutputs, sharedSecret: sharedSecret,
                spendPublicKey: spendPublicKey,
                labels: SilentPaymentReceiving.Labels(scanPrivateKey: testCase.scanPrivateKey,
                                                      labels: testCase.labels))
            #expect(matches.count == testCase.expectedCount, comment)
            guard !testCase.expectedOutputs.isEmpty else { continue }

            let expectedByKey = Dictionary(uniqueKeysWithValues:
                testCase.expectedOutputs.map { ($0.publicKey, $0) })
            for match in matches {
                guard let expected = expectedByKey[match.outputKey] else {
                    Issue.record("unexpected match \(match.outputKey.hex) — \(testCase.comment)")
                    continue
                }
                #expect(match.tweak == expected.privateKeyTweak, comment)

                // Spendability proof: d = b_spend + tweak controls the output.
                // The vector signature is over sha256("message") but its aux
                // randomness is not reproducible, so byte-equality is out;
                // instead verify the vector's signature AND a fresh one of our
                // own against the matched output key.
                let secret = try SilentPaymentSending.scalarAdd(testCase.spendPrivateKey,
                                                                match.tweak)
                let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
                #expect(Data(key.xonly.bytes) == match.outputKey, comment)
                let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: match.outputKey)
                var message = [UInt8](SHA256.hash(data: Data("message".utf8)))
                let vectorSignature = try P256K.Schnorr.SchnorrSignature(
                    dataRepresentation: expected.signature)
                #expect(outputKey.isValid(vectorSignature, for: &message), comment)
                var auxiliaryRand = [UInt8](SHA256.hash(data: Data("random".utf8)))
                let ourSignature = try key.signature(message: &message,
                                                     auxiliaryRand: &auxiliaryRand)
                #expect(outputKey.isValid(ourSignature, for: &message), comment)
            }
        }
    }

    /// BIP352 §Key Derivation: scan m/352'/coin'/account'/1'/0, spend
    /// m/352'/coin'/account'/0'/0. The vectors hand out raw keys, so the paths
    /// are pinned here instead: structurally against child-by-child hardened
    /// derivation, and byte-exact so a refactor cannot silently move them
    /// (that would be a seed-recovery/interop break, not a test failure
    /// anywhere else).
    @Test func keyDerivationPaths() throws {
        let master = try HDKey(seed: Data(hex: "000102030405060708090a0b0c0d0e0f")!)
        let scan = try SilentPaymentReceiving.scanKey(from: master)
        let spend = try SilentPaymentReceiving.spendKey(from: master)

        let hardened = HDKey.hardenedOffset
        let manualScan = try master.child(at: 352 + hardened).child(at: 0 + hardened)
            .child(at: 0 + hardened).child(at: 1 + hardened).child(at: 0)
        let manualSpend = try master.child(at: 352 + hardened).child(at: 0 + hardened)
            .child(at: 0 + hardened).child(at: 0 + hardened).child(at: 0)
        #expect(scan.privateKey == manualScan.privateKey)
        #expect(spend.privateKey == manualSpend.privateKey)
        #expect(scan.privateKey != spend.privateKey)

        // Signet/testnet uses coin type 1 and must not collide with mainnet.
        let testnetScan = try SilentPaymentReceiving.scanKey(from: master, coinType: 1)
        #expect(testnetScan.privateKey != scan.privateKey)

        // Byte pins (this implementation at the BIP32 test seed).
        #expect(scan.privateKey?.hex
            == "18778f6ba4b363113417af64262408b7c28ac02fb443aeefc285269e8186419b")
        #expect(spend.privateKey?.hex
            == "320cb82a9e88ac7c562119f44e049bd0b2e6554a1b9682b0630c4105a7982075")
    }
}
