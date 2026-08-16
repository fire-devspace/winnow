import BitcoinCore
import BitcoinP2P
import Foundation
import P256K
import Testing
@testable import WalletCore

/// Wallet-level silent payment receiving (BIP352): the wallet's own address,
/// the tweak-carrying UTXO state, and spending matched outputs with
/// b_spend + t_k — including as inputs of a further silent-payment send.
@Suite("Silent payment receive flow")
struct SilentPaymentReceiveFlowTests {
    /// A funded sender wallet distinct from the receiver (`testEntropy`).
    private func makeSender() async throws -> (wallet: Wallet, fundingScript: Data) {
        let wallet = try await Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                             entropy: Data(repeating: 1, count: 16),
                                             creationHeight: 100)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let funding = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 150_000, scriptPubKey: script),
        ], locktime: 0)
        try await wallet.apply(match: fakeMatch(height: 100, transactions: [funding]))
        return (wallet, script)
    }

    /// The receiver's BIP352 keys, derived outside the wallet for comparison.
    private func receiverKeys() throws -> (scan: HDKey, spend: HDKey) {
        let master = try testMaster()
        return (try SilentPaymentReceiving.scanKey(from: master, coinType: 1),
                try SilentPaymentReceiving.spendKey(from: master, coinType: 1))
    }

    @Test("the wallet derives its own static silent payment address")
    func walletAddress() async throws {
        let wallet = try await Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                             entropy: testEntropy, creationHeight: 100)
        let address = try await wallet.silentPaymentAddress()
        #expect(address.hasPrefix("tsp1"))
        let keys = try receiverKeys()
        let expected = try SilentPaymentAddress(scanKey: keys.scan.publicKey,
                                                spendKey: keys.spend.publicKey, hrp: "tsp").encoded
        #expect(address == expected)
    }

    @Test("UTXO JSON: tweak round-trips; pre-SP files stay identical")
    func utxoCoding() throws {
        let utxo = WalletUTXO(txid: Data(repeating: 0xAB, count: 32), vout: 1, amount: 5,
                              scriptPubKey: Data([0x51, 0x20]) + Data(repeating: 2, count: 32),
                              chain: .receive, index: 0, height: 9)
        let encoded = try JSONEncoder().encode(utxo)
        #expect(!String(data: encoded, encoding: .utf8)!.contains("silentPaymentTweak"))
        #expect(try JSONDecoder().decode(WalletUTXO.self, from: encoded) == utxo)

        var withTweak = utxo
        withTweak.silentPaymentTweak = Data(repeating: 7, count: 32)
        let reDecoded = try JSONDecoder().decode(WalletUTXO.self,
                                                 from: try JSONEncoder().encode(withTweak))
        #expect(reDecoded == withTweak)
    }

    @Test("round trip: pay the wallet's address, scan, re-open, spend")
    func receiveScanOpenSpend() async throws {
        let (sender, senderScript) = try await makeSender()

        let receiverStore = InMemoryKeyStore()
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-flow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        let receiver = try await Wallet.create(network: .signet, keyStore: receiverStore,
                                               storageURL: storageURL, entropy: testEntropy,
                                               creationHeight: 100)
        let address = try await receiver.silentPaymentAddress()
        let built = try await sender.send(
            payments: [], feeRateSatPerVByte: 2,
            silentPayments: [try SilentPayment(amount: 100_000, address: address, network: .signet)])
        let tx = built.transaction

        // Receive-side scan from the raw transaction — the same quantities the
        // tweak-index/filter pipeline will feed.
        let keys = try receiverKeys()
        let inputKeys = tx.inputs.compactMap {
            SilentPaymentSending.eligiblePublicKey(prevoutScriptPubKey: senderScript,
                                                   scriptSig: $0.scriptSig, witness: $0.witness)
        }
        #expect(inputKeys.count == 1)
        let sum = try #require(try SilentPaymentReceiving.inputPublicKeySum(inputKeys))
        let smallestOutpoint = tx.inputs.map { input -> Data in
            var littleEndianVout = input.previousOutput.vout.littleEndian
            return input.previousOutput.txid + withUnsafeBytes(of: &littleEndianVout) { Data($0) }
        }.min(by: { $0.lexicographicallyPrecedes($1) })!
        let tweakData = try SilentPaymentReceiving.tweakData(inputPublicKeySum: sum,
                                                             smallestOutpoint: smallestOutpoint)
        let sharedSecret = try SilentPaymentReceiving.sharedSecret(
            scanPrivateKey: keys.scan.privateKey!, tweakData: tweakData)
        let candidates = tx.outputs
            .filter { $0.scriptPubKey.count == 34 && $0.scriptPubKey.first == 0x51 }
            .map { Data($0.scriptPubKey.dropFirst(2)) }
        let matches = try SilentPaymentReceiving.scan(outputs: candidates,
                                                      sharedSecret: sharedSecret,
                                                      spendPublicKey: keys.spend.publicKey)
        // Exactly the payment — the sender's own P2TR change does not match.
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        let vout = try #require(tx.outputs.firstIndex {
            $0.scriptPubKey == Data([0x51, 0x20]) + match.outputKey
        })
        #expect(tx.outputs[vout].value == 100_000)

        // Persist the matched output into the receiver's state file and
        // re-open (the pipeline chunk will route this through the wallet; the
        // schema and signing path are what's under test).
        var state = try JSONDecoder().decode(WalletState.self, from: Data(contentsOf: storageURL))
        state.utxos.append(WalletUTXO(txid: tx.txid, vout: UInt32(vout),
                                      amount: tx.outputs[vout].value,
                                      scriptPubKey: tx.outputs[vout].scriptPubKey,
                                      chain: .receive, index: 0, height: 101,
                                      silentPaymentTweak: match.tweak))
        try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
        let reopened = try Wallet.open(storageURL: storageURL, keyStore: receiverStore)
        #expect(await reopened.balance == 100_000)

        // Spend it and verify the key-path signature against the
        // silent-payment output key (no TapTweak).
        let destination = try await sender.scriptPubKey(chain: .receive, index: 1)
        let prepared = try await reopened.buildSend(
            payments: [Payment(amount: 60_000, scriptPubKey: destination)], feeRateSatPerVByte: 2)
        let spend = prepared.built.transaction
        #expect(spend.inputs.count == 1)
        #expect(spend.inputs[0].previousOutput == Transaction.Outpoint(txid: tx.txid,
                                                                       vout: UInt32(vout)))
        let witness = spend.inputs[0].witness
        #expect(witness.count == 1)
        let sighash = try SighashBIP341.sighash(
            tx: spend, inputIndex: 0,
            spentOutputs: [SighashBIP341.SpentOutput(amount: 100_000,
                                                     scriptPubKey: tx.outputs[vout].scriptPubKey)],
            hashType: .default)
        var message = [UInt8](sighash)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: witness[0])
        #expect(P256K.Schnorr.XonlyKey(dataRepresentation: match.outputKey)
            .isValid(signature, for: &message))
    }

    @Test("a silent-payment UTXO correctly keys a further silent-payment send")
    func silentPaymentInputFundsSilentPaymentSend() async throws {
        // Fabricate a matched output for the receiver: pick a tweak, then the
        // output key IS (b_spend + tweak)·G by construction.
        let keys = try receiverKeys()
        let tweak = try SilentPaymentReceiving.labelTweak(scanPrivateKey: keys.scan.privateKey!,
                                                          label: 42) // any valid scalar
        let outputSecret = try SilentPaymentReceiving.spendSecret(
            spendPrivateKey: keys.spend.privateKey!, tweak: tweak)
        let outputKey = Data(try P256K.Schnorr.PrivateKey(dataRepresentation: outputSecret).xonly.bytes)
        let script = Data([0x51, 0x20]) + outputKey
        let txid = Data(repeating: 0xC1, count: 32)

        let receiverStore = InMemoryKeyStore()
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-fund-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storageURL) }
        _ = try await Wallet.create(network: .signet, keyStore: receiverStore,
                                    storageURL: storageURL, entropy: testEntropy,
                                    creationHeight: 100)
        var state = try JSONDecoder().decode(WalletState.self, from: Data(contentsOf: storageURL))
        state.utxos.append(WalletUTXO(txid: txid, vout: 0, amount: 150_000, scriptPubKey: script,
                                      chain: .receive, index: 0, height: 101,
                                      silentPaymentTweak: tweak))
        try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
        let wallet = try Wallet.open(storageURL: storageURL, keyStore: receiverStore)

        let scanKey = try P256K.Signing.PrivateKey().publicKey.dataRepresentation
        let spendKey = try P256K.Signing.PrivateKey().publicKey.dataRepresentation
        let recipient = try SilentPaymentAddress(scanKey: scanKey, spendKey: spendKey, hrp: "tsp")
        let built = try await wallet.send(payments: [], feeRateSatPerVByte: 2,
                                          silentPayments: [SilentPayment(amount: 100_000,
                                                                         address: recipient)])

        // Independently derive the recipient's expected output script with
        // d = b_spend + tweak as the input key — if the wallet keyed the
        // derivation with BIP86 coordinates instead, the scripts disagree and
        // the payment would be unfindable by the recipient (fund loss).
        let input = SilentPaymentSending.Input(txid: txid, vout: 0, prevoutScriptPubKey: script,
                                               privateKey: outputSecret)
        let expected = try SilentPaymentSending.outputScripts(inputs: [input],
                                                              recipients: [recipient])
        #expect(built.transaction.outputs.contains {
            $0.value == 100_000 && $0.scriptPubKey == expected[0]
        })
    }
}
