import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// The keyPathSpending section of the official BIP341 wallet test vectors
/// (bip341-wallet-test-vectors.json): intermediate sha_* hashes, the exact
/// SigMsg bytes, the final sighash, and the expected witness signatures.
@Suite("BIP341 sighash vectors")
struct SighashBIP341Tests {
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
        let json = try JSONSerialization.jsonObject(with: vectorData("bip341-wallet-test-vectors.json")) as! [String: Any]
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
}
