import BitcoinP2P
import Foundation
import Testing
@testable import WalletCore

@Suite("Coin selection")
struct CoinSelectionTests {
    let p2tr = Data([0x51, 0x20] + repeatElement(0x42, count: 32))

    func utxo(_ amount: Int64, index: UInt32 = 0) -> WalletUTXO {
        WalletUTXO(txid: Data(repeating: UInt8(amount % 250 + 1), count: 32), vout: index,
                   amount: amount, scriptPubKey: p2tr, chain: .receive, index: index, height: 100)
    }

    @Test("dust thresholds follow Core's GetDustThreshold (3000 sat/kvB)")
    func dustThresholds() {
        // P2TR: 43-byte txout + 67-byte discounted witness input = 110 × 3.
        #expect(CoinSelection.dustThreshold(scriptPubKey: p2tr) == 330)
        // P2WPKH: 31 + 67 = 98 × 3 = 294.
        #expect(CoinSelection.dustThreshold(scriptPubKey: Data([0x00, 0x14] + repeatElement(0x42, count: 20))) == 294)
        // P2PKH: 34 + 148 = 182 × 3 = 546.
        #expect(CoinSelection.dustThreshold(scriptPubKey: Data([0x76, 0xA9, 0x14] + repeatElement(0x42, count: 20) + [0x88, 0xAC])) == 546)
        // OP_RETURN outputs carry no dust threshold in Core (unspendable) —
        // we simply don't special-case them; verify P2TR scales with feerate.
        #expect(CoinSelection.dustThreshold(scriptPubKey: p2tr, relayFeeSatPerKvB: 6_000) == 660)
    }

    @Test("largest-first: the biggest UTXOs are spent first")
    func largestFirst() throws {
        let utxos = [utxo(10_000, index: 0), utxo(500_000, index: 1), utxo(50_000, index: 2)]
        let payments = [Payment(amount: 100_000, scriptPubKey: p2tr)]
        let selection = try CoinSelection.select(utxos: utxos, payments: payments,
                                                 changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        #expect(selection.selected.map(\.amount) == [500_000])
        #expect(selection.changeAmount != nil)
        // fee = vsize(1 in, payment + change) × 1 sat/vB; change = rest.
        let expectedVSize = TransactionBuilder.signedVSize(inputCount: 1, outputs: [
            Transaction.Output(value: 100_000, scriptPubKey: p2tr),
            Transaction.Output(value: 0, scriptPubKey: p2tr),
        ])
        #expect(selection.fee == Int64(expectedVSize))
        #expect(selection.changeAmount == 500_000 - 100_000 - Int64(expectedVSize))
    }

    @Test("dust change folds into the fee instead of creating a dust output")
    func dustChange() throws {
        let payments = [Payment(amount: 100_000, scriptPubKey: p2tr)]
        let changeScript = p2tr
        // Pick the UTXO so the remainder after the 2-output fee is 100 sats.
        let vsizeWithChange = TransactionBuilder.signedVSize(inputCount: 1, outputs: [
            Transaction.Output(value: 100_000, scriptPubKey: p2tr),
            Transaction.Output(value: 0, scriptPubKey: changeScript),
        ])
        let amount = 100_000 + Int64(vsizeWithChange) + 100
        let selection = try CoinSelection.select(utxos: [utxo(amount)], payments: payments,
                                                 changeScriptPubKey: changeScript, feeRateSatPerVByte: 1)
        #expect(selection.changeAmount == nil)
        #expect(selection.fee == amount - 100_000) // fee + 100 dust sats
    }

    @Test("exact change (remainder == fee) creates no change output")
    func exactChange() throws {
        let payments = [Payment(amount: 100_000, scriptPubKey: p2tr)]
        let vsizeWithChange = TransactionBuilder.signedVSize(inputCount: 1, outputs: [
            Transaction.Output(value: 100_000, scriptPubKey: p2tr),
            Transaction.Output(value: 0, scriptPubKey: p2tr),
        ])
        let amount = 100_000 + Int64(vsizeWithChange) // remainder exactly the 2-output fee
        let selection = try CoinSelection.select(utxos: [utxo(amount)], payments: payments,
                                                 changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        #expect(selection.changeAmount == nil)
        #expect(selection.fee == Int64(vsizeWithChange))
        // …and the fee still covers the smaller 1-output transaction.
        let vsizeNoChange = TransactionBuilder.signedVSize(inputCount: 1, outputs: [
            Transaction.Output(value: 100_000, scriptPubKey: p2tr),
        ])
        #expect(selection.fee >= Int64(vsizeNoChange))
    }

    @Test("insufficient funds and empty UTXO set throw")
    func failures() {
        let payments = [Payment(amount: 1_000_000, scriptPubKey: p2tr)]
        #expect(throws: CoinSelectionError.noUTXOs) {
            _ = try CoinSelection.select(utxos: [], payments: payments,
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        do {
            _ = try CoinSelection.select(utxos: [utxo(50_000)], payments: payments,
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
            Issue.record("should have thrown insufficientFunds")
        } catch let CoinSelectionError.insufficientFunds(available, required) {
            #expect(available == 50_000)
            #expect(required > 1_000_000) // target + fee for the changeless tx
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("a payment below its dust threshold is rejected before building")
    func subDustPaymentRejected() {
        // 100 sats to a P2TR script (dust threshold 330) must not build a
        // non-relayable tx that then strands the committed inputs.
        let payments = [Payment(amount: 100, scriptPubKey: p2tr)]
        #expect(throws: CoinSelectionError.dustOutput(value: 100, threshold: 330)) {
            _ = try CoinSelection.select(utxos: [utxo(1_000_000)], payments: payments,
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        // At the threshold it is accepted.
        #expect(throws: Never.self) {
            _ = try CoinSelection.select(utxos: [utxo(1_000_000)],
                                         payments: [Payment(amount: 330, scriptPubKey: p2tr)],
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
    }

    @Test("non-positive, non-finite, or absurd feerates are rejected")
    func feeRateSanity() {
        let payments = [Payment(amount: 100_000, scriptPubKey: p2tr)]
        for bad in [0.0, -5.0, Double.nan, Double.infinity, 10_001.0] {
            #expect(throws: CoinSelectionError.self) {
                _ = try CoinSelection.select(utxos: [utxo(1_000_000)], payments: payments,
                                             changeScriptPubKey: p2tr, feeRateSatPerVByte: bad)
            }
        }
        // The boundary rate is accepted.
        #expect(throws: Never.self) {
            _ = try CoinSelection.select(utxos: [utxo(100_000_000)], payments: payments,
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 10_000)
        }
    }

    @Test("multiple inputs are pulled in until the growing fee is covered")
    func multipleInputs() throws {
        // 4 × 60_000, target 200_000: 3 inputs (180k) don't cover it, 4 do.
        let utxos = (0 ..< 4).map { utxo(60_000, index: UInt32($0)) }
        let payments = [Payment(amount: 200_000, scriptPubKey: p2tr)]
        let selection = try CoinSelection.select(utxos: utxos, payments: payments,
                                                 changeScriptPubKey: p2tr, feeRateSatPerVByte: 2)
        let vsize = TransactionBuilder.signedVSize(inputCount: 4, outputs: [
            Transaction.Output(value: 200_000, scriptPubKey: p2tr),
            Transaction.Output(value: 0, scriptPubKey: p2tr),
        ])
        #expect(selection.selected.count == 4)
        #expect(selection.fee == Int64(2 * vsize))
        #expect(selection.changeAmount == 240_000 - 200_000 - Int64(2 * vsize))
    }

    @Test("hostile amounts and malformed wallet coins fail without arithmetic traps")
    func hostileAmountsAndCoins() {
        let valid = utxo(1_000_000)

        #expect(throws: CoinSelectionError.invalidAmount(Int64.max)) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: Int64.max, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        #expect(throws: CoinSelectionError.amountOverflow) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [
                    Payment(amount: BitcoinAmount.maximum, scriptPubKey: p2tr),
                    Payment(amount: 330, scriptPubKey: p2tr),
                ], changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        #expect(throws: CoinSelectionError.duplicateUTXO) {
            _ = try CoinSelection.select(
                utxos: [valid, valid], payments: [Payment(amount: 10_000, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }

        var badOutpoint = valid
        badOutpoint.txid = Data(repeating: 0x11, count: 31)
        #expect(throws: CoinSelectionError.invalidOutpoint) {
            _ = try CoinSelection.select(
                utxos: [badOutpoint], payments: [Payment(amount: 10_000, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        #expect(throws: CoinSelectionError.emptyScript) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: 10_000, scriptPubKey: Data())],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        #expect(throws: CoinSelectionError.invalidWitnessSize(-1)) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: 10_000, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1,
                witnessBytesPerInput: -1)
        }
    }
}
