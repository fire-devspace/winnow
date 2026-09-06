import Foundation
import P256K
import Testing
@testable import BitcoinCore

/// Official BIP327 MuSig2 test vectors (bitcoin/bips bip-0327/vectors):
/// key sorting, key aggregation with tweaks, nonce generation/aggregation,
/// partial signing/verification, and final signature aggregation — including
/// the x-only tweak cases that Taproot vaults rely on.
@Suite("BIP327 MuSig2 vectors")
struct MuSig2Tests {
    static func vectors(_ name: String) throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil,
                                          subdirectory: "Vectors/bip327") else {
            throw VectorError.missingFile(name)
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func hex(_ value: String) -> Data { value.isEmpty ? Data() : Data(hex: value)! }
    static func hexList(_ value: Any) -> [Data] { (value as! [String]).map(hex) }

    @Test("key sort")
    func keySort() throws {
        let vectors = try Self.vectors("key_sort_vectors.json")
        let pubkeys = Self.hexList(vectors["pubkeys"]!)
        let sorted = Self.hexList(vectors["sorted_pubkeys"]!)
        #expect(MuSig.keySort(pubkeys) == sorted)
    }

    @Test("key aggregation, including tweaked contexts")
    func keyAgg() throws {
        let vectors = try Self.vectors("key_agg_vectors.json")
        let pubkeys = Self.hexList(vectors["pubkeys"]!)
        let tweaks = Self.hexList(vectors["tweaks"]!)
        for testCase in vectors["valid_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let context = try MuSig.keyAggContext(publicKeys: keys)
            #expect(context.xonlyAggregateKey == Self.hex(testCase["expected"] as! String))
            #expect(context.parityAccumulator == MuSig.scalarOne)
            #expect(context.tweakAccumulator == MuSig.scalarZero)
        }
        for testCase in vectors["error_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let caseTweaks = (testCase["tweak_indices"] as! [Int]).map { tweaks[$0] }
            let isXOnly = testCase["is_xonly"] as! [Bool]
            #expect(throws: MuSig.MuSig2Error.self) {
                var context = try MuSig.keyAggContext(publicKeys: keys)
                for (tweak, xonly) in zip(caseTweaks, isXOnly) {
                    context = try MuSig.applyTweak(context, tweak: tweak, isXOnly: xonly)
                }
            }
        }
    }

    @Test("nonce generation")
    func nonceGen() throws {
        let vectors = try Self.vectors("nonce_gen_vectors.json")
        for (index, testCase) in (vectors["test_cases"] as! [[String: Any]]).enumerated() {
            // BIP327 distinguishes an absent message (0x00 prefix) from an
            // empty one (0x01 || 8-byte length) — "" is the empty byte array.
            func maybe(_ key: String) -> Data? { (testCase[key] as? String).map(Self.hex) }
            let (secretNonce, publicNonce) = try MuSig.nonceGenerate(
                secretKey: maybe("sk"),
                publicKey: Self.hex(testCase["pk"] as! String),
                aggregateKey: maybe("aggpk"),
                message: maybe("msg"),
                extraInput: maybe("extra_in"),
                rand: Self.hex(testCase["rand_"] as! String))
            #expect(secretNonce == Self.hex(testCase["expected_secnonce"] as! String), "case \(index)")
            #expect(publicNonce == Self.hex(testCase["expected_pubnonce"] as! String), "case \(index)")
        }
    }

    @Test("nonce aggregation, with the infinity encoding")
    func nonceAgg() throws {
        let vectors = try Self.vectors("nonce_agg_vectors.json")
        let nonces = Self.hexList(vectors["pnonces"]!)
        for testCase in vectors["valid_test_cases"] as! [[String: Any]] {
            let selected = (testCase["pnonce_indices"] as! [Int]).map { nonces[$0] }
            #expect(try MuSig.nonceAggregate(publicNonces: selected) == Self.hex(testCase["expected"] as! String))
        }
        for testCase in vectors["error_test_cases"] as! [[String: Any]] {
            let selected = (testCase["pnonce_indices"] as! [Int]).map { nonces[$0] }
            #expect(throws: MuSig.MuSig2Error.self) { _ = try MuSig.nonceAggregate(publicNonces: selected) }
        }
    }

    @Test("partial sign and verify")
    func signVerify() throws {
        let vectors = try Self.vectors("sign_verify_vectors.json")
        let secret = Self.hex(vectors["sk"] as! String)
        let pubkeys = Self.hexList(vectors["pubkeys"]!)
        let secnonces = Self.hexList(vectors["secnonces"]!)
        let nonces = Self.hexList(vectors["pnonces"]!)
        let aggnonces = Self.hexList(vectors["aggnonces"]!)
        let messages = Self.hexList(vectors["msgs"]!)

        for testCase in vectors["valid_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let selected = (testCase["nonce_indices"] as! [Int]).map { nonces[$0] }
            let aggnonce = aggnonces[testCase["aggnonce_index"] as! Int]
            // The vector nonces must aggregate to the given aggnonce.
            #expect(try MuSig.nonceAggregate(publicNonces: selected) == aggnonce)
            let message = messages[testCase["msg_index"] as! Int]
            let signerIndex = testCase["signer_index"] as! Int
            let expected = Self.hex(testCase["expected"] as! String)

            let session = MuSig.Session(aggregateNonce: aggnonce, publicKeys: keys, message: message)
            var secnonce = secnonces[0]
            let partial = try MuSig.partialSign(secretNonce: &secnonce, secretKey: secret, session: session)
            #expect(partial == expected)
            #expect(secnonce.allSatisfy { $0 == 0 }) // single-use: zeroed after signing
            #expect(try MuSig.partialVerify(partialSignature: partial, publicNonce: selected[signerIndex],
                                            publicKey: keys[signerIndex], session: session))
        }

        for testCase in vectors["sign_error_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let session = MuSig.Session(aggregateNonce: aggnonces[testCase["aggnonce_index"] as! Int],
                                        publicKeys: keys, message: messages[testCase["msg_index"] as! Int])
            var secnonce = secnonces[testCase["secnonce_index"] as! Int]
            #expect(throws: MuSig.MuSig2Error.self) {
                _ = try MuSig.partialSign(secretNonce: &secnonce, secretKey: secret, session: session)
            }
        }

        for testCase in vectors["verify_fail_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let selected = (testCase["nonce_indices"] as! [Int]).map { nonces[$0] }
            let signerIndex = testCase["signer_index"] as! Int
            let session = MuSig.Session(aggregateNonce: try MuSig.nonceAggregate(publicNonces: selected),
                                        publicKeys: keys, message: messages[testCase["msg_index"] as! Int])
            let valid = try MuSig.partialVerify(partialSignature: Self.hex(testCase["sig"] as! String),
                                                publicNonce: selected[signerIndex],
                                                publicKey: keys[signerIndex], session: session)
            #expect(!valid)
        }

        for testCase in vectors["verify_error_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let selected = (testCase["nonce_indices"] as! [Int]).map { nonces[$0] }
            let signerIndex = testCase["signer_index"] as! Int
            #expect(throws: MuSig.MuSig2Error.self) {
                let session = MuSig.Session(aggregateNonce: try MuSig.nonceAggregate(publicNonces: selected),
                                            publicKeys: keys, message: messages[testCase["msg_index"] as! Int])
                _ = try MuSig.partialVerify(partialSignature: Self.hex(testCase["sig"] as! String),
                                            publicNonce: selected[signerIndex],
                                            publicKey: keys[signerIndex], session: session)
            }
        }
    }

    @Test("signing with plain and x-only tweaks (the Taproot vault shape)")
    func tweaks() throws {
        let vectors = try Self.vectors("tweak_vectors.json")
        let secret = Self.hex(vectors["sk"] as! String)
        let pubkeys = Self.hexList(vectors["pubkeys"]!)
        let secnonce = Self.hex(vectors["secnonce"] as! String)
        let nonces = Self.hexList(vectors["pnonces"]!)
        let aggnonce = Self.hex(vectors["aggnonce"] as! String)
        let tweaks = Self.hexList(vectors["tweaks"]!)
        let message = Self.hex(vectors["msg"] as! String)

        for testCase in vectors["valid_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let caseTweaks = (testCase["tweak_indices"] as! [Int]).map { tweaks[$0] }
            let isXOnly = testCase["is_xonly"] as! [Bool]
            let signerIndex = testCase["signer_index"] as! Int
            let session = MuSig.Session(aggregateNonce: aggnonce, publicKeys: keys,
                                        tweaks: caseTweaks, isXOnlyTweaks: isXOnly, message: message)
            var nonce = secnonce
            let partial = try MuSig.partialSign(secretNonce: &nonce, secretKey: secret, session: session)
            #expect(partial == Self.hex(testCase["expected"] as! String))
            let selected = (testCase["nonce_indices"] as! [Int]).map { nonces[$0] }
            #expect(try MuSig.partialVerify(partialSignature: partial, publicNonce: selected[signerIndex],
                                            publicKey: keys[signerIndex], session: session))
        }

        for testCase in vectors["error_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let caseTweaks = (testCase["tweak_indices"] as! [Int]).map { tweaks[$0] }
            let session = MuSig.Session(aggregateNonce: aggnonce, publicKeys: keys,
                                        tweaks: caseTweaks, isXOnlyTweaks: testCase["is_xonly"] as! [Bool],
                                        message: message)
            var nonce = secnonce
            #expect(throws: MuSig.MuSig2Error.self) {
                _ = try MuSig.partialSign(secretNonce: &nonce, secretKey: secret, session: session)
            }
        }
    }

    @Test("partial signature aggregation yields a BIP340-verifiable signature")
    func sigAgg() throws {
        let vectors = try Self.vectors("sig_agg_vectors.json")
        let pubkeys = Self.hexList(vectors["pubkeys"]!)
        let nonces = Self.hexList(vectors["pnonces"]!)
        let tweaks = Self.hexList(vectors["tweaks"]!)
        let partials = Self.hexList(vectors["psigs"]!)
        let message = Self.hex(vectors["msg"] as! String)

        for testCase in vectors["valid_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let caseTweaks = (testCase["tweak_indices"] as! [Int]).map { tweaks[$0] }
            let isXOnly = testCase["is_xonly"] as! [Bool]
            let sigs = (testCase["psig_indices"] as! [Int]).map { partials[$0] }
            let aggnonce = Self.hex(testCase["aggnonce"] as! String)
            let session = MuSig.Session(aggregateNonce: aggnonce, publicKeys: keys,
                                        tweaks: caseTweaks, isXOnlyTweaks: isXOnly, message: message)
            let signature = try MuSig.partialSigAggregate(partialSignatures: sigs, session: session)
            #expect(signature == Self.hex(testCase["expected"] as! String))
            // The aggregate signature verifies against the tweaked aggregate key.
            let aggregateKey = try MuSig.aggregateXonly(publicKeys: keys, tweaks: caseTweaks, isXOnlyTweaks: isXOnly)
            let key = P256K.Schnorr.XonlyKey(dataRepresentation: aggregateKey)
            var messageBytes = [UInt8](message)
            #expect(key.isValid(try P256K.Schnorr.SchnorrSignature(dataRepresentation: signature),
                                for: &messageBytes))
        }

        for testCase in vectors["error_test_cases"] as! [[String: Any]] {
            let keys = (testCase["key_indices"] as! [Int]).map { pubkeys[$0] }
            let caseTweaks = (testCase["tweak_indices"] as! [Int]).map { tweaks[$0] }
            let sigs = (testCase["psig_indices"] as! [Int]).map { partials[$0] }
            let session = MuSig.Session(aggregateNonce: Self.hex(testCase["aggnonce"] as! String),
                                        publicKeys: keys, tweaks: caseTweaks,
                                        isXOnlyTweaks: testCase["is_xonly"] as! [Bool], message: message)
            #expect(throws: MuSig.MuSig2Error.self) {
                _ = try MuSig.partialSigAggregate(partialSignatures: sigs, session: session)
            }
        }
    }
}
