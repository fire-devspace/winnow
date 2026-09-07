import Foundation
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// The official BIP341 sighash test vectors, both spend paths.
///
/// Two suites merged here, each a section below and each with its own vector
/// file under `Vectors/`: the key path from the BIP's own wallet vectors, and
/// the script path (BIP342 ext_flag = 1) from vectors generated once with
/// Bitcoin Core's test framework.
@Suite("BIP341 sighash vectors")
struct SighashBIP341Tests {
    // MARK: - BIP341 sighash vectors
    //
    // The keyPathSpending section of the official BIP341 wallet test vectors
    // (bip341-wallet-test-vectors.json): intermediate sha_* hashes, the exact
    // SigMsg bytes, the final sighash, and the expected witness signatures.

    struct InputVector {
        let index: Int
        let internalPrivkey: Data
        let merkleRoot: Data?
        let hashType: UInt8
        let tweakedPrivkey: Data
        let sigMsg: Data
        let sigHash: Data
        let witness: Data
    }

    struct Vector {
        let tx: Transaction
        let spentOutputs: [SighashBIP341.SpentOutput]
        let hashPrevouts: Data
        let hashAmounts: Data
        let hashScriptPubkeys: Data
        let hashSequences: Data
        let hashOutputs: Data
        let inputs: [InputVector]
    }

    static func vector() throws -> Vector {
        let json = try Vectors.json("bip341-wallet-test-vectors.json", in: .module) as! [String: Any]
        let spending = (json["keyPathSpending"] as! [[String: Any]])[0]
        func hex(_ value: String) throws -> Data {
            guard let data = Data(hex: value) else { throw VectorError.badHex(value) }
            return data
        }
        let given = spending["given"] as! [String: Any]
        let tx = try Transaction.decode(hex(given["rawUnsignedTx"] as! String))
        let spentOutputs = try (given["utxosSpent"] as! [[String: Any]]).map { utxo in
            try SighashBIP341.SpentOutput(amount: Int64(utxo["amountSats"] as! Int),
                                          scriptPubKey: hex(utxo["scriptPubKey"] as! String))
        }
        let intermediary = spending["intermediary"] as! [String: Any]
        let inputs = try (spending["inputSpending"] as! [[String: Any]]).map { entry in
            let given = entry["given"] as! [String: Any]
            let intermediary = entry["intermediary"] as! [String: Any]
            let expected = entry["expected"] as! [String: Any]
            return try InputVector(
                index: given["txinIndex"] as! Int,
                internalPrivkey: hex(given["internalPrivkey"] as! String),
                merkleRoot: (given["merkleRoot"] as? String).flatMap { Data(hex: $0) },
                hashType: UInt8(given["hashType"] as! Int),
                tweakedPrivkey: hex(intermediary["tweakedPrivkey"] as! String),
                sigMsg: hex(intermediary["sigMsg"] as! String),
                sigHash: hex(intermediary["sigHash"] as! String),
                witness: hex((expected["witness"] as! [String])[0])
            )
        }
        return try Vector(tx: tx, spentOutputs: spentOutputs,
                          hashPrevouts: hex(intermediary["hashPrevouts"] as! String),
                          hashAmounts: hex(intermediary["hashAmounts"] as! String),
                          hashScriptPubkeys: hex(intermediary["hashScriptPubkeys"] as! String),
                          hashSequences: hex(intermediary["hashSequences"] as! String),
                          hashOutputs: hex(intermediary["hashOutputs"] as! String),
                          inputs: inputs)
    }

    @Test("common signature-message hashes (sha_prevouts … sha_outputs)")
    func commonHashes() throws {
        let vector = try Self.vector()
        let common = try SighashBIP341.commonHashes(tx: vector.tx, spentOutputs: vector.spentOutputs)
        #expect(common.prevouts == vector.hashPrevouts)
        #expect(common.amounts == vector.hashAmounts)
        #expect(common.scriptPubKeys == vector.hashScriptPubkeys)
        #expect(common.sequences == vector.hashSequences)
        #expect(common.outputs == vector.hashOutputs)
    }

    @Test("per-input SigMsg bytes and sighash, all hash types")
    func sigMsgAndSighash() throws {
        let vector = try Self.vector()
        for input in vector.inputs {
            let hashType = SighashBIP341.HashType(rawValue: input.hashType)
            #expect(hashType.isValid)
            let message = try SighashBIP341.signatureMessage(tx: vector.tx, inputIndex: input.index,
                                                             spentOutputs: vector.spentOutputs, hashType: hashType)
            #expect(message == input.sigMsg, "input \(input.index) sigMsg")
            let sighash = try SighashBIP341.sighash(tx: vector.tx, inputIndex: input.index,
                                                    spentOutputs: vector.spentOutputs, hashType: hashType)
            #expect(sighash == input.sigHash, "input \(input.index) sigHash")
        }
    }

    @Test("tweaked private keys (TapTweak with the given merkle roots)")
    func tweakedKeys() throws {
        let vector = try Self.vector()
        for input in vector.inputs {
            let internalPubkey = Data(try P256K.Schnorr.PrivateKey(dataRepresentation: input.internalPrivkey).xonly.bytes)
            let tweak = Taproot.tweak(internalKey: internalPubkey, merkleRoot: input.merkleRoot)
            let tweaked = try P256K.Schnorr.PrivateKey(dataRepresentation: input.internalPrivkey)
                .add([UInt8](tweak)).dataRepresentation
            #expect(tweaked == input.tweakedPrivkey, "input \(input.index)")
        }
    }

    @Test("expected witness signatures verify, and our signer reproduces them (aux = 0)")
    func witnessSignatures() throws {
        let vector = try Self.vector()
        for input in vector.inputs {
            let hashType = SighashBIP341.HashType(rawValue: input.hashType)
            // The spent output's scriptPubKey commits to the tweaked output key.
            let outputKey = vector.spentOutputs[input.index].scriptPubKey.suffix(32)
            let key = P256K.Schnorr.XonlyKey(dataRepresentation: outputKey)
            var message = [UInt8](input.sigHash)
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: input.witness.prefix(64))
            #expect(key.isValid(signature, for: &message), "input \(input.index) witness must verify")
            // 64-byte sig for SIGHASH_DEFAULT, otherwise the hash type byte is appended.
            if hashType == .default {
                #expect(input.witness.count == 64)
            } else {
                #expect(input.witness.count == 65 && input.witness.last == input.hashType)
            }

            // The vectors use zero auxiliary randomness; our signer must
            // reproduce the exact witness bytes with aux = 0.
            let witness = try Signer.witness(tx: vector.tx, inputIndex: input.index,
                                             spentOutputs: vector.spentOutputs,
                                             tweakedPrivateKey: input.tweakedPrivkey,
                                             hashType: hashType,
                                             auxiliaryRand: Data(repeating: 0, count: 32))
            #expect(witness == [input.witness], "input \(input.index) witness bytes")
        }
    }

    @Test("invalid hash types and SINGLE without a matching output throw")
    func validation() throws {
        let vector = try Self.vector()
        #expect(throws: SighashError.self) {
            _ = try SighashBIP341.sighash(tx: vector.tx, inputIndex: 0,
                                          spentOutputs: vector.spentOutputs,
                                          hashType: SighashBIP341.HashType(rawValue: 0x04))
        }
        // The vector tx has 2 outputs; SINGLE on input 3 has no matching output.
        #expect(throws: SighashError.singleWithoutCorrespondingOutput(index: 3)) {
            _ = try SighashBIP341.sighash(tx: vector.tx, inputIndex: 3,
                                          spentOutputs: vector.spentOutputs, hashType: .single)
        }
        #expect(throws: SighashError.inputIndexOutOfRange(index: 9, count: 9)) {
            _ = try SighashBIP341.sighash(tx: vector.tx, inputIndex: 9,
                                          spentOutputs: vector.spentOutputs, hashType: .default)
        }
        #expect(throws: SighashError.spentOutputCountMismatch(inputs: 9, spentOutputs: 1)) {
            _ = try SighashBIP341.sighash(tx: vector.tx, inputIndex: 0,
                                          spentOutputs: Array(vector.spentOutputs.prefix(1)),
                                          hashType: .default)
        }
    }

    // MARK: - BIP341 script-path sighash vectors
    //
    // BIP341 script-path (BIP342 ext_flag = 1) test vectors
    // (bip341-scriptpath-test-vectors.json, generated once with Bitcoin Core's
    // test framework): a tr(NUMS, multi_a(2, K1, K2, K3)) vault spent with all
    // eight hash types, with and without an annex — SigMsg bytes, sighash, the
    // expected signatures, and the full BIP387 witness stack.
    //
    // Its `InputVector`, `Vector` and `vector()` collided with the key-path
    // section's, so they are `ScriptPathInputVector`, `ScriptPathVector` and
    // `scriptPathVector()` here.

    struct ScriptPathInputVector {
        let index: Int
        let leafScript: Script
        let controlBlock: Taproot.ControlBlock
        let hashType: UInt8
        let annex: Data?
        let signingSecrets: [Data]
        let sigMsg: Data
        let sigHash: Data
        let signatures: [Data: Data] // x-only leaf key → sig item
        let witness: [Data]
    }

    struct ScriptPathVector {
        let tx: Transaction
        let spentOutputs: [SighashBIP341.SpentOutput]
        let internalKey: Data
        let leafKeys: [Data]
        let threshold: Int
        let inputs: [ScriptPathInputVector]
    }

    static func scriptPathVector() throws -> ScriptPathVector {
        let json = try Vectors.json("bip341-scriptpath-test-vectors.json", in: .module) as! [String: Any]
        func hex(_ value: String) throws -> Data {
            guard let data = Data(hex: value) else { throw VectorError.badHex(value) }
            return data
        }
        let given = json["given"] as! [String: Any]
        let tx = try Transaction.decode(hex(given["rawUnsignedTx"] as! String))
        let spentOutputs = try (given["utxosSpent"] as! [[String: Any]]).map { utxo in
            try SighashBIP341.SpentOutput(amount: Int64(utxo["amountSats"] as! Int),
                                          scriptPubKey: hex(utxo["scriptPubKey"] as! String))
        }
        let inputs = try (json["inputSpending"] as! [[String: Any]]).map { entry in
            let given = entry["given"] as! [String: Any]
            let intermediary = entry["intermediary"] as! [String: Any]
            let expected = entry["expected"] as! [String: Any]
            var signatures: [Data: Data] = [:]
            for (key, sig) in expected["signatures"] as! [String: String] {
                signatures[Data(hex: key)!] = Data(hex: sig)!
            }
            return try ScriptPathInputVector(
                index: given["txinIndex"] as! Int,
                leafScript: Script(hex: given["leafScript"] as! String)!,
                controlBlock: Taproot.ControlBlock(serialized: hex(given["controlBlock"] as! String)),
                hashType: UInt8(given["hashType"] as! Int),
                annex: (given["annex"] as? String).flatMap { Data(hex: $0) },
                signingSecrets: (given["signingSecrets"] as! [String]).map { Data(hex: $0)! },
                sigMsg: hex(intermediary["sigMsg"] as! String),
                sigHash: hex(intermediary["sigHash"] as! String),
                signatures: signatures,
                witness: (expected["witness"] as! [String]).map { Data(hex: $0) ?? Data() }
            )
        }
        return try ScriptPathVector(tx: tx, spentOutputs: spentOutputs,
                                    internalKey: hex(given["internalKey"] as! String),
                                    leafKeys: (given["leafKeys"] as! [String]).map { Data(hex: $0)! },
                                    threshold: given["threshold"] as! Int,
                                    inputs: inputs)
    }

    @Test("the vault is the NUMS internal key plus a multi_a leaf, parsed back")
    func fixtureShape() throws {
        let vector = try Self.scriptPathVector()
        #expect(vector.internalKey == Taproot.unspendableInternalKey)
        for input in vector.inputs {
            let parsed = try #require(Multisig.parse(input.leafScript))
            #expect(parsed.threshold == vector.threshold)
            #expect(parsed.keys == vector.leafKeys)
            // The control block commits the leaf to the spent scriptPubKey.
            #expect(input.controlBlock.internalKey == vector.internalKey)
            let program = vector.spentOutputs[input.index].scriptPubKey.suffix(32)
            let (outputKey, parity) = try Taproot.tweakedOutputKey(
                internalKey: vector.internalKey,
                merkleRoot: Taproot.leafHash(script: input.leafScript))
            #expect(outputKey == program)
            #expect(input.controlBlock.outputKeyParity == parity)
        }
    }

    @Test("SigMsg bytes and sighash for all hash types, script-path + annex")
    func scriptPathSigMsgAndSighash() throws {
        let vector = try Self.scriptPathVector()
        for input in vector.inputs {
            let hashType = SighashBIP341.HashType(rawValue: input.hashType)
            #expect(hashType.isValid)
            let scriptPath = SighashBIP341.ScriptPath(leafScript: input.leafScript)
            let message = try SighashBIP341.signatureMessage(tx: vector.tx, inputIndex: input.index,
                                                             spentOutputs: vector.spentOutputs,
                                                             hashType: hashType,
                                                             scriptPath: scriptPath, annex: input.annex)
            #expect(message == input.sigMsg, "input \(input.index) hashType \(input.hashType) sigMsg")
            let sighash = try SighashBIP341.sighash(tx: vector.tx, inputIndex: input.index,
                                                    spentOutputs: vector.spentOutputs,
                                                    hashType: hashType,
                                                    scriptPath: scriptPath, annex: input.annex)
            #expect(sighash == input.sigHash, "input \(input.index) hashType \(input.hashType) sigHash")
        }
    }

    @Test("script-path signatures verify against the leaf keys (aux = 0 reproduces)")
    func signatures() throws {
        let vector = try Self.scriptPathVector()
        for input in vector.inputs {
            let hashType = SighashBIP341.HashType(rawValue: input.hashType)
            for secret in input.signingSecrets {
                let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
                let xonly = Data(key.xonly.bytes)
                let expected = try #require(input.signatures[xonly])
                // The vector signature verifies against the leaf key + sighash.
                var message = [UInt8](input.sigHash)
                let parsed = try P256K.Schnorr.SchnorrSignature(dataRepresentation: expected.prefix(64))
                #expect(P256K.Schnorr.XonlyKey(dataRepresentation: xonly).isValid(parsed, for: &message))
                // Our signer (no tweak!) reproduces the exact bytes with aux = 0.
                let signature = try Signer.scriptPathSignature(
                    tx: vector.tx, inputIndex: input.index, spentOutputs: vector.spentOutputs,
                    leafScript: input.leafScript, hashType: hashType, annex: input.annex,
                    privateKey: secret, auxiliaryRand: Data(repeating: 0, count: 32))
                #expect(signature == expected, "input \(input.index) hashType \(input.hashType) key \(xonly.hex)")
            }
        }
    }

    @Test("BIP387 witness construction: reversed key order, empty placeholder")
    func witness() throws {
        let vector = try Self.scriptPathVector()
        for input in vector.inputs {
            let witness = try Signer.multisigWitness(signatures: input.signatures,
                                                     leafScript: input.leafScript,
                                                     controlBlock: input.controlBlock)
            #expect(witness == input.witness, "input \(input.index) hashType \(input.hashType)")
            // Layout: n sig slots (middle key empty), then script, then control block.
            #expect(witness.count == vector.leafKeys.count + 2)
            #expect(witness[vector.leafKeys.count] == input.leafScript.bytes)
            #expect(witness.last == input.controlBlock.serialized)
            #expect(witness[1] == Data()) // the non-signing middle key's placeholder
        }
    }
}
