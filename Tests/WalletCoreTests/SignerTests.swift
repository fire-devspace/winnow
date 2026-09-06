import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// End-to-end key-path signing: fake UTXO set → build tx → sighash → sign →
/// verify the witness Schnorr signatures against the spent outputs' tweaked
/// keys with P256K. A real cryptographic round trip, no network.
@Suite("Signer")
struct SignerTests {
    /// A fake UTXO set paying BIP86 signet addresses of the test mnemonic.
    struct Fixture {
        let master: HDKey
        var utxos: [(outpoint: Transaction.Outpoint, spent: SighashBIP341.SpentOutput, tweakedKey: Data)] = []

        init(indices: [UInt32], amounts: [Int64]) throws {
            master = try testMaster()
            for (position, index) in indices.enumerated() {
                let key = try master.derived(path: "m/86'/1'/0'/0/\(index)")
                let internalKey = BIP86.xonlyPublicKey(of: key)
                let script = try BIP86.scriptPubKey(internalKey: internalKey)
                let tweaked = try BIP86.tweakedPrivateKey(key.privateKey!)
                let outpoint = Transaction.Outpoint(txid: Data(repeating: UInt8(0x30 + position), count: 32),
                                                    vout: 0)
                utxos.append((outpoint, SighashBIP341.SpentOutput(amount: amounts[position],
                                                                  scriptPubKey: script), tweaked))
            }
        }
    }

    @Test("sign a two-input spend and verify both witnesses against the output keys")
    func signAndVerify() throws {
        let fixture = try Fixture(indices: [0, 1], amounts: [100_000, 50_000])
        let destinationInternal = try BIP86.internalKey(from: fixture.master, coinType: 1, change: 0, index: 10)
        let destination = try AddressDecoder.scriptPubKey(
            for: BIP86.address(internalKey: destinationInternal, hrp: "tb"), network: .signet)
        var tx = try TransactionBuilder.build(inputs: fixture.utxos.map(\.outpoint),
                                              payments: [Payment(amount: 120_000, scriptPubKey: destination)],
                                              change: nil)
        let spentOutputs = fixture.utxos.map(\.spent)
        try Signer.sign(tx: &tx, spentOutputs: spentOutputs) { script in
            fixture.utxos.first { $0.spent.scriptPubKey == script }?.tweakedKey
        }

        #expect(tx.isSegwit)
        for (index, utxo) in fixture.utxos.enumerated() {
            #expect(tx.inputs[index].witness.count == 1)
            let signatureData = tx.inputs[index].witness[0]
            #expect(signatureData.count == 64) // SIGHASH_DEFAULT

            // Verify against the tweaked output key committed by the scriptPubKey.
            let sighash = try SighashBIP341.sighash(tx: tx, inputIndex: index,
                                                    spentOutputs: spentOutputs, hashType: .default)
            let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: utxo.spent.scriptPubKey.suffix(32))
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: signatureData)
            var message = [UInt8](sighash)
            #expect(outputKey.isValid(signature, for: &message), "input \(index) must verify")
        }

        // The fully-signed transaction round-trips through the wire parser.
        let decoded = try Transaction.decode(tx.serialized(includeWitness: true))
        #expect(decoded == tx)
    }

    @Test("SIGHASH_ALL appends the hash type byte; fixed aux rand is deterministic")
    func sighashAllDeterministic() throws {
        let fixture = try Fixture(indices: [2], amounts: [75_000])
        let destination = Data([0x51, 0x20] + repeatElement(0x99, count: 32))
        let tx = try TransactionBuilder.build(inputs: fixture.utxos.map(\.outpoint),
                                              payments: [Payment(amount: 70_000, scriptPubKey: destination)])
        let witness1 = try Signer.witness(tx: tx, inputIndex: 0, spentOutputs: fixture.utxos.map(\.spent),
                                          tweakedPrivateKey: fixture.utxos[0].tweakedKey,
                                          hashType: .all, auxiliaryRand: Data(repeating: 0, count: 32))
        let witness2 = try Signer.witness(tx: tx, inputIndex: 0, spentOutputs: fixture.utxos.map(\.spent),
                                          tweakedPrivateKey: fixture.utxos[0].tweakedKey,
                                          hashType: .all, auxiliaryRand: Data(repeating: 0, count: 32))
        #expect(witness1 == witness2)
        #expect(witness1[0].count == 65 && witness1[0].last == 0x01)

        let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: fixture.utxos[0].spent.scriptPubKey.suffix(32))
        let sighash = try SighashBIP341.sighash(tx: tx, inputIndex: 0,
                                                spentOutputs: fixture.utxos.map(\.spent), hashType: .all)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: witness1[0].prefix(64))
        var message = [UInt8](sighash)
        #expect(outputKey.isValid(signature, for: &message))
    }

    @Test("a resolver that finds no key throws missingKey")
    func missingKey() throws {
        let fixture = try Fixture(indices: [0], amounts: [10_000])
        var tx = try TransactionBuilder.build(inputs: fixture.utxos.map(\.outpoint),
                                              payments: [Payment(amount: 9_000,
                                                                 scriptPubKey: Data([0x51, 0x20] + repeatElement(0x99, count: 32)))])
        #expect(throws: SignerError.self) {
            try Signer.sign(tx: &tx, spentOutputs: fixture.utxos.map(\.spent)) { _ in nil }
        }
    }

    @Test("spent-output count mismatch is an error, not an index trap")
    func spentOutputCountMismatch() throws {
        let fixture = try Fixture(indices: [0], amounts: [10_000])
        var tx = try TransactionBuilder.build(
            inputs: fixture.utxos.map(\.outpoint),
            payments: [Payment(amount: 9_000,
                               scriptPubKey: Data([0x51, 0x20] + repeatElement(0x99, count: 32)))])
        #expect(throws: SignerError.spentOutputCountMismatch(inputs: 1, spentOutputs: 0)) {
            try Signer.sign(tx: &tx, spentOutputs: []) { _ in nil }
        }
        #expect(tx.inputs[0].witness.isEmpty)
    }
}
