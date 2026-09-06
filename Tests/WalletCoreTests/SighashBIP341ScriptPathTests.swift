import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// BIP341 script-path (BIP342 ext_flag = 1) test vectors
/// (bip341-scriptpath-test-vectors.json, generated once with Bitcoin Core's
/// test framework): a tr(NUMS, multi_a(2, K1, K2, K3)) vault spent with all
/// eight hash types, with and without an annex — SigMsg bytes, sighash, the
/// expected signatures, and the full BIP387 witness stack.
@Suite("BIP341 script-path sighash vectors")
struct SighashBIP341ScriptPathTests {
    struct InputVector {
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

    struct Vector {
        let tx: Transaction
        let spentOutputs: [SighashBIP341.SpentOutput]
        let internalKey: Data
        let leafKeys: [Data]
        let threshold: Int
        let inputs: [InputVector]
    }

    static func vector() throws -> Vector {
        let json = try JSONSerialization.jsonObject(with: vectorData("bip341-scriptpath-test-vectors.json")) as! [String: Any]
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
            return try InputVector(
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
        return try Vector(tx: tx, spentOutputs: spentOutputs,
                          internalKey: hex(given["internalKey"] as! String),
                          leafKeys: (given["leafKeys"] as! [String]).map { Data(hex: $0)! },
                          threshold: given["threshold"] as! Int,
                          inputs: inputs)
    }

    @Test("the vault is the NUMS internal key plus a multi_a leaf, parsed back")
    func fixtureShape() throws {
        let vector = try Self.vector()
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
    func sigMsgAndSighash() throws {
        let vector = try Self.vector()
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
        let vector = try Self.vector()
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
        let vector = try Self.vector()
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
