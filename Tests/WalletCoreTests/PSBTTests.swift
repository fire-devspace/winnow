import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// PSBTv2 (BIP370) + BIP371 Taproot fields: creator → signer → finalizer →
/// extractor, wire round-trips, and generic-map preservation of unknown pairs.
@Suite("PSBT")
struct PSBTTests {
    struct Fixture {
        let master: HDKey
        let tx: Transaction
        let inputs: [PSBT.InputInfo]
        let outputs: [PSBT.OutputInfo]
        let tweakedKeys: [Data]

        init() throws {
            master = try testMaster()
            var inputs: [PSBT.InputInfo] = []
            var tweakedKeys: [Data] = []
            var outpoints: [Transaction.Outpoint] = []
            for index: UInt32 in [0, 1] {
                let key = try master.derived(path: "m/86'/1'/0'/0/\(index)")
                let internalKey = BIP86.xonlyPublicKey(of: key)
                let script = try BIP86.scriptPubKey(internalKey: internalKey)
                outpoints.append(Transaction.Outpoint(txid: Data(repeating: UInt8(0x40 + index), count: 32),
                                                      vout: index))
                inputs.append(PSBT.InputInfo(
                    spentOutput: .init(amount: Int64(100_000 + index * 10_000), scriptPubKey: script),
                    key: .init(internalKey: internalKey, masterFingerprint: master.fingerprint,
                               path: [86, 1, 0].map { $0 + HDKey.hardenedOffset } + [0, index])))
                tweakedKeys.append(try BIP86.tweakedPrivateKey(key.privateKey!))
            }
            let paymentScript = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
            let changeKey = try master.derived(path: "m/86'/1'/0'/1/0")
            let changeInternal = BIP86.xonlyPublicKey(of: changeKey)
            tx = try TransactionBuilder.build(
                inputs: outpoints,
                payments: [Payment(amount: 100_000, scriptPubKey: paymentScript)],
                change: Payment(amount: 99_500, scriptPubKey: BIP86.scriptPubKey(internalKey: changeInternal)),
                changePosition: 1)
            let outputInfo = [PSBT.OutputInfo(key: nil),
                              PSBT.OutputInfo(key: .init(internalKey: changeInternal,
                                                         masterFingerprint: master.fingerprint,
                                                         path: [86, 1, 0].map { $0 + HDKey.hardenedOffset } + [1, 0]))]
            self.inputs = inputs
            outputs = outputInfo
            self.tweakedKeys = tweakedKeys
        }
    }

    @Test("creator emits the BIP370 v2 fields and BIP371 Taproot fields")
    func creatorFields() throws {
        let fixture = try Fixture()
        let psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)

        #expect(psbt.version == 2)
        #expect(psbt.txVersion == 2)
        #expect(psbt.inputs.count == 2 && psbt.outputs.count == 2)
        for (index, input) in psbt.inputs.enumerated() {
            #expect(input.previousTxid == fixture.tx.inputs[index].previousOutput.txid)
            #expect(input.outputIndex == fixture.tx.inputs[index].previousOutput.vout)
            #expect(input.sequence == 0xFFFF_FFFD)
            #expect(input.sighashType == 0) // SIGHASH_DEFAULT, explicit
            #expect(input.witnessUTXO == fixture.inputs[index].spentOutput)
            #expect(input.tapInternalKey == fixture.inputs[index].key?.internalKey)
            let origin = try #require(input.tapBIP32Derivation[fixture.inputs[index].key!.internalKey])
            #expect(origin.leafHashes.isEmpty) // key-path only
            #expect(origin.masterFingerprint == fixture.master.fingerprint)
            #expect(origin.path.count == 5)
        }
        #expect(psbt.outputs[0].amount == 100_000)
        #expect(psbt.outputs[0].tapInternalKey == nil) // external payment
        #expect(psbt.outputs[1].tapInternalKey != nil) // change, ours
        #expect(try psbt.unsignedTransaction() == fixture.tx)
    }

    @Test("signer refuses a non-output-committing sighash type")
    func signerRefusesNonCommittingSighash() throws {
        // A malicious PSBT creator sets SIGHASH_NONE/SINGLE/ANYONECANPAY to
        // collect signatures that don't commit to the outputs, then rewrites
        // them. The signer must refuse every such type; DEFAULT/ALL still sign.
        for badType: UInt32 in [0x02, 0x03, 0x81, 0x82, 0x83] {
            let fixture = try Fixture()
            var psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
            psbt.inputs[0].sighashType = badType
            #expect(throws: PSBTError.self) {
                try psbt.signKeyPath(input: 0, tweakedPrivateKey: fixture.tweakedKeys[0])
            }
        }
        for okType: UInt32 in [0x00, 0x01] {
            let fixture = try Fixture()
            var psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
            psbt.inputs[0].sighashType = okType
            #expect(throws: Never.self) {
                try psbt.signKeyPath(input: 0, tweakedPrivateKey: fixture.tweakedKeys[0])
            }
        }
    }

    @Test("serialize → parse round trip preserves everything, Base64 included")
    func wireRoundTrip() throws {
        let fixture = try Fixture()
        var psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
        // An unknown proprietary pair (Phase 5 will define real ones) must survive.
        psbt.inputs[0].pairs.append(PSBT.KeyValue(type: 0xFC, keyData: Data("acme".utf8), value: Data([1, 2, 3])))

        let parsed = try PSBT(serialized: psbt.serialized)
        #expect(parsed == psbt)
        #expect(parsed.inputs[0].pairs.contains { $0.type == 0xFC && $0.value == Data([1, 2, 3]) })
        #expect(try PSBT(base64: psbt.base64) == psbt)
    }

    @Test("signer → finalizer → extractor produces the fully-signed raw tx")
    func roles() throws {
        let fixture = try Fixture()
        var psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
        for index in fixture.tweakedKeys.indices {
            try psbt.signKeyPath(input: index, tweakedPrivateKey: fixture.tweakedKeys[index],
                                 auxiliaryRand: Data(repeating: 0, count: 32))
        }
        #expect(psbt.inputs.allSatisfy { $0.tapKeySignature?.count == 64 })

        try psbt.finalize()
        // Finalizer clears the in-progress fields (BIP174).
        #expect(psbt.inputs.allSatisfy { $0.tapKeySignature == nil && $0.finalScriptWitness?.count == 1 })

        let signed = try psbt.extractedTransaction()
        #expect(signed.isSegwit)

        // Every witness verifies against the spent output key.
        let spentOutputs = fixture.inputs.map(\.spentOutput)
        for index in signed.inputs.indices {
            let sighash = try SighashBIP341.sighash(tx: signed, inputIndex: index,
                                                    spentOutputs: spentOutputs, hashType: .default)
            let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: spentOutputs[index].scriptPubKey.suffix(32))
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: signed.inputs[index].witness[0])
            var message = [UInt8](sighash)
            #expect(outputKey.isValid(signature, for: &message))
        }

        // The extracted tx is exactly what direct signing produces (aux = 0).
        var direct = fixture.tx
        try Signer.sign(tx: &direct, spentOutputs: spentOutputs,
                        auxiliaryRand: Data(repeating: 0, count: 32)) { script in
            fixture.inputs.firstIndex { $0.spentOutput.scriptPubKey == script }
                .map { fixture.tweakedKeys[$0] }
        }
        #expect(signed == direct)
    }

    @Test("unsignedTransaction/extractor enforce presence of required fields")
    func validation() throws {
        let fixture = try Fixture()
        let psbt = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
        #expect(throws: PSBTError.self) { _ = try psbt.extractedTransaction() } // nothing signed yet
        var mutable = psbt
        #expect(throws: PSBTError.self) { try mutable.finalize() }

        // Bad magic, v0 PSBT, duplicate keys.
        #expect(throws: PSBTError.invalidMagic) { _ = try PSBT(serialized: Data([1, 2, 3, 4, 5])) }
        var v0Globals = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
        v0Globals.append(contentsOf: [0x01, 0xFB, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]) // version = 0
        #expect(throws: PSBTError.unsupportedVersion(0)) { _ = try PSBT(serialized: v0Globals) }
        var duplicate = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
        duplicate.append(contentsOf: [0x01, 0xFB, 0x01, 0x02, 0x01, 0xFB, 0x01, 0x02, 0x00])
        #expect(throws: PSBTError.duplicateKey(Data([0xFB]))) { _ = try PSBT(serialized: duplicate) }
    }

    @Test("hostile PSBT lengths and fixed-width fields fail closed")
    func hostileLengths() throws {
        let oversized = Data(repeating: 0, count: PSBT.maxSerializedSize + 1)
        #expect(throws: PSBTError.malformed("document exceeds \(PSBT.maxSerializedSize) bytes")) {
            _ = try PSBT(serialized: oversized)
        }
        let oversizedBase64 = String(repeating: "A", count: PSBT.maxBase64Length + 1)
        #expect(throws: PSBTError.malformed("Base64 text exceeds \(PSBT.maxBase64Length) bytes")) {
            _ = try PSBT(base64: oversizedBase64)
        }

        // A CompactSize UInt64.max used to trap while converting to Int.
        var impossibleKey = Data([0x70, 0x73, 0x62, 0x74, 0xFF, 0xFF])
        impossibleKey.append(contentsOf: repeatElement(UInt8(0xFF), count: 8))
        #expect(throws: PSBTError.malformed("map key length \(UInt64.max) is out of bounds")) {
            _ = try PSBT(serialized: impossibleKey)
        }

        // Fixed-width fields are validated before any computed property can
        // load beyond the supplied bytes.
        var badVersion = Data([0x70, 0x73, 0x62, 0x74, 0xFF])
        badVersion.append(contentsOf: [0x01, PSBT.GlobalType.version, 0x00, 0x00])
        #expect(throws: PSBTError.malformed("global version must be four bytes")) {
            _ = try PSBT(serialized: badVersion)
        }

        let fixture = try Fixture()
        var malformedInput = try PSBT(unsignedTx: fixture.tx, inputs: fixture.inputs, outputs: fixture.outputs)
        let outputIndex = try #require(malformedInput.inputs[0].pairs.firstIndex {
            $0.type == PSBT.InType.outputIndex
        })
        malformedInput.inputs[0].pairs[outputIndex].value = Data()
        #expect(throws: PSBTError.malformed("input field \(PSBT.InType.outputIndex) must be 4 bytes")) {
            _ = try PSBT(serialized: malformedInput.serialized)
        }
    }
}
