import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// The Phase-5 PSBT fields and roles: BIP371 leaf fields (tap leaf script,
/// tap script sig, tap tree), BIP373 MuSig2 fields, the combiner role
/// (union merge, conflict/duplicate handling), and script-path finalize
/// including wrong-key rejection.
@Suite("PSBT multisig fields and combiner")
struct PSBTMultisigTests {
    /// A minimal 1-in/1-out PSBTv2 spending a fabricated multi_a vault UTXO.
    struct Fixture {
        let masters: [HDKey]
        let psbt: PSBT
        let tx: Transaction
        let leafScript: Script
        let controlBlock: Taproot.ControlBlock
        let leafKeys: [Data] // x-only, script order
        let secrets: [Data]

        init() throws {
            masters = try [Data(repeating: 0x11, count: 16), Data(repeating: 0x22, count: 16)]
                .map { try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: $0))) }
            secrets = masters.map { $0.privateKey! }
            leafKeys = try secrets.map { Data(try P256K.Schnorr.PrivateKey(dataRepresentation: $0).xonly.bytes) }
            leafScript = try Multisig.script(threshold: 2, xonlyKeys: leafKeys, sorted: false)
            let tree = Taproot.Tree.leaf(script: leafScript)
            controlBlock = try Taproot.controlBlock(internalKey: Taproot.unspendableInternalKey,
                                                    tree: tree, leafIndex: 0)
            let scriptPubKey = try Taproot.scriptPubKey(internalKey: Taproot.unspendableInternalKey,
                                                        merkleRoot: Taproot.merkleRoot(of: tree))
            tx = try TransactionBuilder.build(
                inputs: [Transaction.Outpoint(txid: Data(repeating: 0x99, count: 32), vout: 0)],
                payments: [Payment(amount: 90_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x77, count: 32)))])
            var psbt = try PSBT(unsignedTx: tx,
                                inputs: [PSBT.InputInfo(spentOutput: .init(amount: 100_000,
                                                                           scriptPubKey: scriptPubKey))],
                                outputs: [PSBT.OutputInfo()])
            try psbt.attachScriptPath(input: 0, controlBlock: controlBlock, leafScript: leafScript)
            self.psbt = psbt
        }
    }

    @Test("BIP371 leaf fields round-trip through the wire format")
    func leafFieldRoundTrip() throws {
        let fixture = try Fixture()
        let input = fixture.psbt.inputs[0]
        #expect(input.tapInternalKey == Taproot.unspendableInternalKey)
        let leaves = input.tapLeafScripts
        #expect(leaves.count == 1)
        #expect(leaves[0].controlBlock == fixture.controlBlock)
        #expect(leaves[0].script == fixture.leafScript.bytes)
        #expect(leaves[0].leafVersion == Taproot.leafVersion)
        #expect(leaves[0].leafHash == Taproot.leafHash(script: fixture.leafScript))

        // Signature fields.
        var psbt = fixture.psbt
        let sig = Data(repeating: 0x42, count: 64)
        psbt.inputs[0].tapScriptSignatures = [
            PSBT.TapScriptSignatureID(publicKey: fixture.leafKeys[0], leafHash: leaves[0].leafHash): sig,
        ]
        let parsed = try PSBT(serialized: psbt.serialized)
        #expect(parsed == psbt)
        #expect(parsed.inputs[0].tapScriptSignatures.count == 1)
        #expect(parsed.inputs[0].tapLeafScripts.count == 1)
        #expect(try PSBT(base64: psbt.base64) == psbt)
    }

    @Test("BIP371 tap tree + BIP373 musig2 fields round-trip")
    func outputAndMuSig2Fields() throws {
        var output = PSBT.Output()
        output.tapInternalKey = Taproot.unspendableInternalKey
        output.tapTree = [(depth: 0, leafVersion: Taproot.leafVersion, script: Data([0x51]))]
        var input = PSBT.Input()
        let aggregate = Data([0x02] + repeatElement(0x01, count: 32))
        let participants = [Data([0x02] + repeatElement(0x02, count: 32)),
                            Data([0x03] + repeatElement(0x03, count: 32))]
        input.musig2ParticipantPubKeys = [aggregate: participants]
        let id = PSBT.MuSig2KeyID(participant: participants[0], aggregate: aggregate)
        input.musig2PubNonces = [id: Data(repeating: 0x07, count: 66)]
        input.musig2PartialSigs = [id: Data(repeating: 0x08, count: 32)]
        // With a tapleaf hash suffix (script-path musig) the key grows by 32 bytes.
        let leafID = PSBT.MuSig2KeyID(participant: participants[1], aggregate: aggregate,
                                      leafHash: Data(repeating: 0x09, count: 32))
        var nonces = input.musig2PubNonces
        nonces[leafID] = Data(repeating: 0x0A, count: 66)
        input.musig2PubNonces = nonces

        let psbt = PSBT(globals: [
            PSBT.KeyValue(type: PSBT.GlobalType.inputCount, value: Data([0x01])),
            PSBT.KeyValue(type: PSBT.GlobalType.outputCount, value: Data([0x01])),
            PSBT.KeyValue(type: PSBT.GlobalType.version, value: Data([0x02, 0x00, 0x00, 0x00])),
        ], inputs: [input], outputs: [output])
        let parsed = try PSBT(serialized: psbt.serialized)
        #expect(parsed == psbt)
        #expect(parsed.outputs[0].tapTree?.count == 1)
        #expect(parsed.outputs[0].tapTree?[0].script == Data([0x51]))
        #expect(parsed.inputs[0].musig2ParticipantPubKeys[aggregate] == participants)
        #expect(parsed.inputs[0].musig2PubNonces.count == 2)
        #expect(parsed.inputs[0].musig2PubNonces[leafID] == Data(repeating: 0x0A, count: 66))
        #expect(parsed.inputs[0].musig2PartialSigs[id] == Data(repeating: 0x08, count: 32))
    }

    @Test("script-path signer attaches verified partial signatures")
    func scriptPathSigning() throws {
        let fixture = try Fixture()
        var psbt = fixture.psbt
        try psbt.signScriptPath(input: 0, privateKeys: [fixture.secrets[0]],
                                auxiliaryRand: Data(repeating: 0, count: 32))
        let sigs = psbt.inputs[0].tapScriptSignatures
        #expect(sigs.count == 1)
        let leafHash = Taproot.leafHash(script: fixture.leafScript)
        let sig = try #require(sigs[PSBT.TapScriptSignatureID(publicKey: fixture.leafKeys[0], leafHash: leafHash)])
        #expect(sig.count == 64) // SIGHASH_DEFAULT

        // A key that is not in the leaf signs nothing and throws.
        let outsider = Data(repeating: 0x07, count: 32)
        #expect(throws: PSBTError.self) {
            try psbt.signScriptPath(input: 0, privateKeys: [outsider])
        }
        #expect(psbt.inputs[0].tapScriptSignatures.count == 1)
    }

    @Test("combiner: union merge, duplicate dedupe, conflict detection")
    func combiner() throws {
        let fixture = try Fixture()
        var first = fixture.psbt
        var second = fixture.psbt
        try first.signScriptPath(input: 0, privateKeys: [fixture.secrets[0]],
                                 auxiliaryRand: Data(repeating: 0, count: 32))
        try second.signScriptPath(input: 0, privateKeys: [fixture.secrets[1]],
                                  auxiliaryRand: Data(repeating: 0, count: 32))

        let merged = try first.combined(with: [second])
        #expect(merged.inputs[0].tapScriptSignatures.count == 2)
        // Combining is idempotent — identical pairs dedupe.
        #expect(try merged.combined(with: [first]) == merged)
        #expect(try first.combined(with: []) == first)

        // Same key, different value → conflict.
        var conflicted = fixture.psbt
        conflicted.inputs[0].sighashType = 1 // SIGHASH_ALL vs the base DEFAULT
        #expect(throws: PSBTError.conflict(Data([PSBT.InType.sighashType]))) {
            _ = try fixture.psbt.combined(with: [conflicted])
        }

        // A PSBT of a different transaction cannot combine.
        let otherTx = try TransactionBuilder.build(
            inputs: [Transaction.Outpoint(txid: Data(repeating: 0x55, count: 32), vout: 1)],
            payments: [Payment(amount: 1_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x11, count: 32)))])
        var other = try PSBT(unsignedTx: otherTx,
                             inputs: [PSBT.InputInfo(spentOutput: .init(amount: 2_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x11, count: 32))))],
                             outputs: [PSBT.OutputInfo()])
        other.globals = fixture.psbt.globals // same map counts, different tx
        #expect(throws: PSBTError.self) { _ = try fixture.psbt.combined(with: [other]) }
    }

    @Test("finalize: threshold enforcement and wrong-key rejection")
    func finalizeScriptPath() throws {
        let fixture = try Fixture()
        // Below threshold: a single partial of a 2-of-2 cannot finalize.
        var partial = fixture.psbt
        try partial.signScriptPath(input: 0, privateKeys: [fixture.secrets[0]],
                                   auxiliaryRand: Data(repeating: 0, count: 32))
        #expect(throws: PSBTError.self) { try partial.finalize() }

        // Two valid partials finalize into the BIP387 witness.
        var other = fixture.psbt
        try other.signScriptPath(input: 0, privateKeys: [fixture.secrets[1]],
                                 auxiliaryRand: Data(repeating: 0, count: 32))
        var complete = try partial.combined(with: [other])
        try complete.finalize()
        let witness = try #require(complete.inputs[0].finalScriptWitness)
        #expect(witness.count == 4) // 2 sig slots + leaf script + control block
        #expect(witness[2] == fixture.leafScript.bytes)
        #expect(witness[3] == fixture.controlBlock.serialized)
        // Partial fields are cleared by the finalizer (BIP174).
        #expect(complete.inputs[0].tapScriptSignatures.isEmpty)
        #expect(complete.inputs[0].tapLeafScripts.isEmpty)

        // A foreign signature (valid schnorr, wrong key) is discarded by the
        // finalizer — the input stays below threshold and cannot finalize.
        let foreignSecret = Data(repeating: 0x33, count: 32)
        let foreignKey = Data(try P256K.Schnorr.PrivateKey(dataRepresentation: foreignSecret).xonly.bytes)
        let foreignSig = try Signer.scriptPathSignature(
            tx: fixture.tx, inputIndex: 0,
            spentOutputs: [fixture.psbt.inputs[0].witnessUTXO!],
            leafScript: fixture.leafScript, privateKey: foreignSecret,
            auxiliaryRand: Data(repeating: 0, count: 32))
        var poisoned = fixture.psbt
        poisoned.inputs[0].tapScriptSignatures = [
            PSBT.TapScriptSignatureID(publicKey: fixture.leafKeys[0], // attached under a false key id
                                      leafHash: Taproot.leafHash(script: fixture.leafScript)): foreignSig,
            PSBT.TapScriptSignatureID(publicKey: foreignKey,
                                      leafHash: Taproot.leafHash(script: fixture.leafScript)): foreignSig,
        ]
        #expect(foreignKey != fixture.leafKeys[0])
        #expect(throws: PSBTError.self) { try poisoned.finalize() }
    }

    @Test("script-path finalizer verifies the control block against the spent output")
    func finalizerRejectsUncommittedLeaf() throws {
        let fixture = try Fixture()
        var wrongOutput = fixture.psbt
        let unrelatedInternalKey = BIP86.xonlyPublicKey(of: fixture.masters[0])
        wrongOutput.inputs[0].witnessUTXO = .init(
            amount: 100_000,
            scriptPubKey: try BIP86.scriptPubKey(internalKey: unrelatedInternalKey))
        try wrongOutput.signScriptPath(input: 0, privateKeys: fixture.secrets,
                                       auxiliaryRand: Data(repeating: 0, count: 32))
        #expect(throws: PSBTError.self) { try wrongOutput.finalize() }

        var mismatchedVersion = fixture.psbt
        let original = try #require(mismatchedVersion.inputs[0].tapLeafScripts.first)
        mismatchedVersion.inputs[0].tapLeafScripts = [PSBT.TapLeafScript(
            controlBlock: original.controlBlock, script: original.script, leafVersion: 0xC2)]
        try mismatchedVersion.signScriptPath(input: 0, privateKeys: fixture.secrets,
                                             auxiliaryRand: Data(repeating: 0, count: 32))
        #expect(throws: PSBTError.self) { try mismatchedVersion.finalize() }
    }
}
