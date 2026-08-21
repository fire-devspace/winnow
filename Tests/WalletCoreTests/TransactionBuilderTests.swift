import BitcoinCore
import BitcoinP2P
import Foundation
import Testing
@testable import WalletCore

@Suite("Address decoding + transaction building")
struct TransactionBuilderTests {
    // MARK: Address decoding

    @Test("P2TR bech32m address → scriptPubKey (mainnet and signet HRPs)")
    func p2tr() throws {
        let address = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"
        let script = try AddressDecoder.scriptPubKey(for: address, network: .mainnet)
        #expect(script.count == 34 && script.starts(with: [0x51, 0x20]))
        #expect(AddressDecoder.isP2TR(script))
        // Same output key on the signet HRP.
        let signetAddress = try SegwitAddress.encode(hrp: "tb", version: 1, program: script.suffix(32))
        #expect(try AddressDecoder.scriptPubKey(for: signetAddress, network: .signet) == script)
        // Wrong network is rejected.
        #expect(throws: AddressError.self) {
            _ = try AddressDecoder.scriptPubKey(for: address, network: .signet)
        }
    }

    @Test("P2WPKH bech32, base58 P2PKH and P2SH → scriptPubKey")
    func legacyAndV0() throws {
        // BIP173 reference P2WPKH address.
        let p2wpkh = try AddressDecoder.scriptPubKey(for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
                                                     network: .mainnet)
        #expect(p2wpkh == Data(hex: "0014751e76e8199196d454941c45d1b3a323f1433bd6"))
        // P2PKH for the same hash160 (base58 prefix 0x00).
        let p2pkh = try AddressDecoder.scriptPubKey(for: "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", network: .mainnet)
        #expect(p2pkh == Data(hex: "76a914751e76e8199196d454941c45d1b3a323f1433bd688ac"))
        // Signet/testnet P2PKH (prefix 0x6F).
        let testnetP2pkh = try AddressDecoder.scriptPubKey(for: "mrCDrCybB6J1vRfbwM5hemdJz73FwDBC8r",
                                                           network: .signet)
        #expect(testnetP2pkh == Data(hex: "76a914751e76e8199196d454941c45d1b3a323f1433bd688ac"))
        // P2SH (prefix 0x05): hash160 0x89ABCDEFABCDABCDABCDABCDABCDABCDABCDABCD.
        let p2sh = try AddressDecoder.scriptPubKey(for: "3EExK1K1WioG5caKFqP724ymoEXJNsTjnK", network: .mainnet)
        #expect(p2sh == Data(hex: "a91489abcdefabcdabcdabcdabcdabcdabcdabcdabcd87"))
    }

    @Test("garbage and wrong-network addresses throw")
    func invalid() {
        #expect(throws: AddressError.self) {
            _ = try AddressDecoder.scriptPubKey(for: "not-an-address", network: .mainnet)
        }
        // Mainnet base58 on signet.
        #expect(throws: AddressError.self) {
            _ = try AddressDecoder.scriptPubKey(for: "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", network: .signet)
        }
    }

    // MARK: Building

    @Test("unsigned tx shape: version 2, empty scriptSigs, RBF sequence, change position")
    func build() throws {
        let inputs = [Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32), vout: 1)]
        let payments = [Payment(amount: 50_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x22, count: 32)))]
        let change = Payment(amount: 10_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x33, count: 32)))
        let tx = try TransactionBuilder.build(inputs: inputs, payments: payments, change: change,
                                              changePosition: 0)
        #expect(tx.version == 2)
        #expect(tx.inputs.count == 1)
        #expect(tx.inputs[0].scriptSig.isEmpty)
        #expect(tx.inputs[0].sequence == 0xFFFF_FFFD) // BIP125 opt-in
        #expect(tx.outputs.count == 2)
        #expect(tx.outputs[0].value == 10_000) // change inserted first
        #expect(tx.outputs[1].value == 50_000)
        #expect(!tx.isSegwit) // unsigned

        #expect(throws: TxBuildError.noInputs) {
            _ = try TransactionBuilder.build(inputs: [], payments: payments)
        }
        #expect(throws: TxBuildError.invalidAmount(0)) {
            _ = try TransactionBuilder.build(inputs: inputs, payments: [Payment(amount: 0, scriptPubKey: Data([0x51]))])
        }
    }

    @Test("signedVSize estimate matches the actual signed transaction's vsize")
    func vsizeMath() throws {
        // 2 P2TR inputs, one P2TR payment + P2TR change.
        let script = Data([0x51, 0x20] + repeatElement(0x44, count: 32))
        let outputs = [Transaction.Output(value: 100_000, scriptPubKey: script),
                       Transaction.Output(value: 50_000, scriptPubKey: script)]
        let estimate = TransactionBuilder.signedVSize(inputCount: 2, outputs: outputs)

        var tx = try TransactionBuilder.build(
            inputs: [Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32), vout: 0),
                     Transaction.Outpoint(txid: Data(repeating: 0x22, count: 32), vout: 3)],
            payments: outputs.map { Payment(amount: $0.value, scriptPubKey: $0.scriptPubKey) })
        for index in tx.inputs.indices {
            tx.inputs[index].witness = [Data(repeating: 0xAB, count: 64)] // SIGHASH_DEFAULT sig slot
        }
        #expect(TransactionBuilder.vsize(of: tx) == estimate)
    }

    @Test("builder rejects malformed inputs, positions, scripts, and monetary overflow")
    func hostileBuilderInputs() {
        let input = Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32), vout: 0)
        let script = Data([0x51, 0x20] + repeatElement(0x22, count: 32))
        let payment = Payment(amount: 50_000, scriptPubKey: script)

        #expect(throws: TxBuildError.duplicateInput) {
            _ = try TransactionBuilder.build(inputs: [input, input], payments: [payment])
        }
        #expect(throws: TxBuildError.invalidOutpoint) {
            _ = try TransactionBuilder.build(
                inputs: [Transaction.Outpoint(txid: Data(repeating: 0x11, count: 31), vout: 0)],
                payments: [payment])
        }
        #expect(throws: TxBuildError.invalidChangePosition(2)) {
            _ = try TransactionBuilder.build(
                inputs: [input], payments: [payment],
                change: Payment(amount: 10_000, scriptPubKey: script), changePosition: 2)
        }
        #expect(throws: TxBuildError.emptyScript) {
            _ = try TransactionBuilder.build(
                inputs: [input], payments: [Payment(amount: 50_000, scriptPubKey: Data())])
        }
        #expect(throws: TxBuildError.invalidAmount(Int64.max)) {
            _ = try TransactionBuilder.build(
                inputs: [input], payments: [Payment(amount: Int64.max, scriptPubKey: script)])
        }
        #expect(throws: TxBuildError.amountOverflow) {
            _ = try TransactionBuilder.build(inputs: [input], payments: [
                Payment(amount: BitcoinAmount.maximum, scriptPubKey: script),
                Payment(amount: 1, scriptPubKey: script),
            ])
        }
    }
}
