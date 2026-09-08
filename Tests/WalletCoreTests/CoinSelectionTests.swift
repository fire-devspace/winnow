import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Choosing coins and pricing the transaction that spends them.
///
/// Three suites merged here: the scenario tests below, the seeded property
/// tests that assert the same arithmetic holds for every input the function
/// accepts, and the fee policy that decides the rate those two are handed.
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
        // The threshold is a boundary, not a gradient: one satoshi below is dust.
        #expect(throws: CoinSelectionError.dustOutput(value: 329, threshold: 330)) {
            _ = try CoinSelection.select(utxos: [utxo(1_000_000)],
                                         payments: [Payment(amount: 329, scriptPubKey: p2tr)],
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        // At the threshold it is accepted.
        #expect(throws: Never.self) {
            _ = try CoinSelection.select(utxos: [utxo(1_000_000)],
                                         payments: [Payment(amount: 330, scriptPubKey: p2tr)],
                                         changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
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

    /// The ceiling is on the transaction, not on the coin count, so it is
    /// reached at wildly different input counts depending on what each input
    /// has to prove: about 1,700 P2TR key-path spends, or about 200 vault
    /// inputs carrying a 20-key multi_a witness.
    @Test("a selection too large to relay is refused before anything is signed",
          arguments: [66, 2_000])
    func standardSizeCeiling(witnessBytesPerInput: Int) throws {
        // The shape a one-payment send has: the payment plus change. Output
        // *values* do not affect size, so the input count that first exceeds
        // the ceiling can be found before the amounts are chosen.
        let shape = [Transaction.Output(value: 0, scriptPubKey: p2tr),
                     Transaction.Output(value: 0, scriptPubKey: p2tr)]
        var pastCeiling = 1
        while TransactionBuilder.signedVSize(inputCount: pastCeiling, outputs: shape,
                                             witnessBytesPerInput: witnessBytesPerInput)
            <= TransactionBuilder.maximumStandardVSize { pastCeiling += 1 }

        // Equal coins, and a payment that only the last one covers, so the
        // loop takes every coin offered. 200,000 sats each pays the fee the
        // final input adds and still leaves non-dust change.
        let coin: Int64 = 200_000
        func spendEveryCoin(count: Int) throws -> Selection {
            try CoinSelection.select(
                utxos: (0 ..< count).map { utxo(coin, index: UInt32($0)) },
                payments: [Payment(amount: Int64(count - 1) * coin, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1,
                witnessBytesPerInput: witnessBytesPerInput)
        }

        // One input short of the ceiling, the selection is made, change and all.
        let fits = try spendEveryCoin(count: pastCeiling - 1)
        #expect(fits.selected.count == pastCeiling - 1)
        #expect(fits.changeAmount != nil)

        // One input past it, the selection is refused and carries the vsize
        // it measured — and no signature is spent on bytes no peer would take.
        let vsize = TransactionBuilder.signedVSize(inputCount: pastCeiling, outputs: shape,
                                                   witnessBytesPerInput: witnessBytesPerInput)
        #expect(throws: CoinSelectionError.transactionTooLarge(
            vsize: vsize, limit: TransactionBuilder.maximumStandardVSize)) {
            _ = try spendEveryCoin(count: pastCeiling)
        }
    }

    /// The ceiling is measured on the shape the caller will actually build,
    /// which is why the check runs after the change decision rather than
    /// before it. A dust remainder drops the change output, and the
    /// transaction that gets built is one output shorter than the one the
    /// selection loop priced.
    ///
    /// The two shapes are 43 vbytes apart and an input is 57, so there is a
    /// window one input wide where the changeless transaction relays and the
    /// one with change does not. That window is this case: at `fits` inputs
    /// the case above already proves the with-change shape is refused, so a
    /// dust-change selection of the same size succeeding is only possible if
    /// the change output was left out of the measurement.
    @Test("a dust-change selection is sized without the change output it will not build")
    func standardSizeCeilingWithoutChange() throws {
        let payment = Transaction.Output(value: 0, scriptPubKey: p2tr)
        let withChange = [payment, Transaction.Output(value: 0, scriptPubKey: p2tr)]

        // The largest input count whose *changeless* transaction still relays.
        var fits = 1
        while TransactionBuilder.signedVSize(inputCount: fits + 1, outputs: [payment])
            <= TransactionBuilder.maximumStandardVSize { fits += 1 }
        // The window this case needs: the same count with a change output is
        // over the limit. Without it the case would pass on either shape.
        #expect(TransactionBuilder.signedVSize(inputCount: fits, outputs: withChange)
            > TransactionBuilder.maximumStandardVSize)

        // Every coin is spent and the remainder is 100 sats — under the
        // 330-sat P2TR dust threshold, so the change output is dropped and
        // the remainder folds into the fee.
        let coin: Int64 = 200_000
        let remainder: Int64 = 100
        func spendEveryCoinLeavingDust(count: Int) throws -> Selection {
            let feeWithChange = Int64(TransactionBuilder.signedVSize(inputCount: count,
                                                                     outputs: withChange))
            let target = Int64(count) * coin - feeWithChange - remainder
            return try CoinSelection.select(
                utxos: (0 ..< count).map { utxo(coin, index: UInt32($0)) },
                payments: [Payment(amount: target, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }

        let selection = try spendEveryCoinLeavingDust(count: fits)
        #expect(selection.selected.count == fits)
        #expect(selection.changeAmount == nil, "the remainder is dust, so there is no change output")

        // One input past the changeless ceiling it is refused — and the vsize
        // it reports is the changeless one, not the shape the loop priced.
        let vsize = TransactionBuilder.signedVSize(inputCount: fits + 1, outputs: [payment])
        #expect(vsize < TransactionBuilder.signedVSize(inputCount: fits + 1, outputs: withChange))
        #expect(throws: CoinSelectionError.transactionTooLarge(
            vsize: vsize, limit: TransactionBuilder.maximumStandardVSize)) {
            _ = try spendEveryCoinLeavingDust(count: fits + 1)
        }
    }

    @Test("hostile amounts and malformed wallet coins fail without arithmetic traps")
    func hostileAmountsAndCoins() {
        let valid = utxo(1_000_000)

        #expect(throws: CoinSelectionError.invalidAmount(Int64.max)) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: Int64.max, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1)
        }
        // The boundary itself: one satoshi past MAX_MONEY is refused, not wrapped.
        #expect(throws: CoinSelectionError.invalidAmount(BitcoinAmount.maximum + 1)) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: BitcoinAmount.maximum + 1, scriptPubKey: p2tr)],
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
        #expect(throws: CoinSelectionError.invalidWitnessSize(0)) {
            _ = try CoinSelection.select(
                utxos: [valid], payments: [Payment(amount: 10_000, scriptPubKey: p2tr)],
                changeScriptPubKey: p2tr, feeRateSatPerVByte: 1,
                witnessBytesPerInput: 0)
        }
    }

    // MARK: - Properties
    //
    // Integer-boundary properties of coin selection (invariant S9).
    //
    // The scenario tests above check specific cases. The risk this section
    // addresses is different: an arithmetic path that is correct for the
    // amounts someone thought to write down and wrong near a boundary — a fee
    // that underflows into change, a change output that quietly absorbs a
    // satoshi, a sum that wraps. Money is conserved or it is not, and that has
    // to hold for every input the function accepts rather than for a handful
    // of examples.
    //
    // Generation is seeded, so any failure reproduces exactly from the seed
    // printed in the assertion.

    static func script(_ byte: UInt8) -> Data { Data([0x51, 0x20] + repeatElement(byte, count: 32)) }
    static let changeScript = script(0xCC)

    static func generatedUTXO(_ index: Int, amount: Int64) -> WalletUTXO {
        WalletUTXO(txid: Data([UInt8(truncatingIfNeeded: index)] + repeatElement(0x11, count: 31)),
                   vout: UInt32(index), amount: amount, scriptPubKey: script(0xAA),
                   chain: .receive, index: UInt32(index), height: 1)
    }

    /// Everything a successful selection must satisfy, whatever the inputs.
    static func check(_ selection: Selection, payments: [Payment],
                      offered: [WalletUTXO], seed: UInt64, iteration: Int) {
        let context = "seed 0x\(String(seed, radix: 16)) iteration \(iteration)"
        let inputTotal = selection.selected.reduce(Int64(0)) { $0 + $1.amount }
        let paid = payments.reduce(Int64(0)) { $0 + $1.amount }
        let change = selection.changeAmount ?? 0

        // Money is conserved: nothing is created, nothing vanishes.
        #expect(inputTotal == paid + selection.fee + change,
                "value not conserved — \(context)")
        #expect(selection.fee > 0, "non-positive fee — \(context)")
        #expect(change >= 0, "negative change — \(context)")
        #expect(inputTotal <= BitcoinAmount.maximum, "input total above MAX_MONEY — \(context)")

        // A change output that exists must be spendable, not dust.
        if let amount = selection.changeAmount {
            #expect(amount >= CoinSelection.dustThreshold(scriptPubKey: changeScript),
                    "change below the dust threshold — \(context)")
        }

        // Selected coins are a duplicate-free subset of what was offered.
        let offeredOutpoints = Set(offered.map(\.outpoint))
        var seen: Set<Transaction.Outpoint> = []
        for coin in selection.selected {
            #expect(offeredOutpoints.contains(coin.outpoint), "invented a coin — \(context)")
            #expect(seen.insert(coin.outpoint).inserted, "spent a coin twice — \(context)")
        }
    }

    // MARK: Randomized properties

    /// Ordinary magnitudes: the amounts a wallet actually sees.
    @Test("value is conserved across ordinary amounts")
    func conservationOrdinary() throws {
        let seed: UInt64 = 0x5309_1A7E_0000_0001
        var rng = SeededRandom(state: seed)
        var accepted = 0
        for iteration in 0 ..< 4_000 {
            let utxos = (0 ... rng.count(6)).map { Self.generatedUTXO($0, amount: rng.int(1 ... 5_000_000)) }
            let payments = (0 ... rng.count(3)).map {
                _ in Payment(amount: rng.int(1 ... 2_000_000), scriptPubKey: Self.script(0xBB))
            }
            let rate = Double(rng.int(1 ... 500))
            do {
                let selection = try CoinSelection.select(
                    utxos: utxos, payments: payments,
                    changeScriptPubKey: Self.changeScript, feeRateSatPerVByte: rate)
                Self.check(selection, payments: payments, offered: utxos, seed: seed, iteration: iteration)
                accepted += 1
            } catch is CoinSelectionError {
                continue // a refusal is always an acceptable answer
            }
        }
        #expect(accepted > 500, "the generator produced too few accepted selections to be meaningful")
    }

    /// Amounts pressed against MAX_MONEY, where an unchecked add would wrap.
    /// Every one of these must either succeed with money conserved or throw —
    /// never return a wrong number.
    @Test("extreme amounts either conserve value or are refused")
    func conservationAtExtremes() throws {
        let seed: UInt64 = 0x5309_1A7E_0000_0002
        var rng = SeededRandom(state: seed)
        let extremes: [Int64] = [
            1, 2, 329, 330, 331,
            BitcoinAmount.maximum - 1, BitcoinAmount.maximum,
            Int64.max / 2, Int64.max - 1, Int64.max,
        ]
        for iteration in 0 ..< 3_000 {
            let utxos = (0 ... rng.count(4)).map {
                Self.generatedUTXO($0, amount: extremes[rng.count(extremes.count)])
            }
            let payments = (0 ... rng.count(2)).map {
                _ in Payment(amount: extremes[rng.count(extremes.count)], scriptPubKey: Self.script(0xBB))
            }
            let rate = [0.25, 1, 1_000, 9_999, 10_000][rng.count(5)]
            do {
                let selection = try CoinSelection.select(
                    utxos: utxos, payments: payments,
                    changeScriptPubKey: Self.changeScript, feeRateSatPerVByte: rate)
                Self.check(selection, payments: payments, offered: utxos, seed: seed, iteration: iteration)
            } catch is CoinSelectionError {
                continue
            }
        }
    }

    // MARK: Named boundaries

    /// A fee rate is bounded on both sides. Zero, negative, NaN and infinity
    /// would each underflow the fee and inflate change past the inputs;
    /// anything above Core's relay ceiling silently burns the balance.
    @Test("fee rates outside (0, 10000] are refused",
          arguments: [0.0, -1.0, -5.0, -0.0001, 10_000.001, 10_001.0, 100_000.0,
                      Double.nan, Double.infinity, -Double.infinity])
    func feeRateBounds(_ rate: Double) {
        // Asserting the specific case matters: with the ceiling removed the
        // call still throws, but as insufficientFunds, because an absurd rate
        // simply exhausts the inputs. A test that accepted any
        // CoinSelectionError would pass against a missing bound.
        do {
            _ = try CoinSelection.select(
                utxos: [Self.generatedUTXO(0, amount: 1_000_000)],
                payments: [Payment(amount: 100_000, scriptPubKey: Self.script(0xBB))],
                changeScriptPubKey: Self.changeScript, feeRateSatPerVByte: rate)
            Issue.record("fee rate \(rate) was accepted")
        } catch let error as CoinSelectionError {
            guard case .invalidFeeRate = error else {
                Issue.record("fee rate \(rate) was rejected as \(error) rather than invalidFeeRate")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// Both ends of the accepted fee-rate range still produce a conserved
    /// selection, so the bounds above are refusals rather than the only
    /// values that work. The top of the range is named by `FeePolicy` rather
    /// than repeated here, so a policy ceiling raised past the band selection
    /// enforces fails this case.
    @Test("the extreme accepted fee rates still conserve value",
          arguments: [0.0001, FeePolicy.maximumSatPerVByte])
    func acceptedFeeRateExtremes(_ rate: Double) throws {
        let utxos = [Self.generatedUTXO(0, amount: BitcoinAmount.maximum / 4)]
        let payments = [Payment(amount: 1_000_000, scriptPubKey: Self.script(0xBB))]
        let selection = try CoinSelection.select(
            utxos: utxos, payments: payments,
            changeScriptPubKey: Self.changeScript, feeRateSatPerVByte: rate)
        Self.check(selection, payments: payments, offered: utxos, seed: 0, iteration: 0)
    }

    /// The other half of that tie. `FeePolicy.maximumSatPerVByte` and the band
    /// `checkArguments` enforces are separate constants, so this pins the first
    /// rate past the policy's ceiling to a refusal — and to `invalidFeeRate`
    /// rather than insufficient funds, which a widened band would still throw.
    @Test("the first fee rate past the fee policy's maximum is refused")
    func feeRateAboveFeePolicyMaximum() {
        let rate = FeePolicy.maximumSatPerVByte.nextUp
        #expect(throws: CoinSelectionError.invalidFeeRate(rate)) {
            try CoinSelection.select(
                utxos: [Self.generatedUTXO(0, amount: 1_000_000)],
                payments: [Payment(amount: 100_000, scriptPubKey: Self.script(0xBB))],
                changeScriptPubKey: Self.changeScript, feeRateSatPerVByte: rate)
        }
    }

    // MARK: - Fee policy
    //
    // Which rate the selection above is handed, and the floor the peer pool
    // puts under it.

    @Test("resolution order: override > observed median > static preset")
    func order() {
        // Static presets when nothing else is known.
        #expect(FeePolicy.resolve(priority: .low) == FeePolicy.Priority.low.satPerVByte)
        #expect(FeePolicy.resolve(priority: .medium) == 5)
        #expect(FeePolicy.resolve(priority: .high) == 12)
        // Observed median beats the preset.
        #expect(FeePolicy.resolve(priority: .high, observed: [3, 7, 4]) == 4)
        // The user override beats everything.
        #expect(FeePolicy.resolve(priority: .high, override: 42, observed: [3, 7, 4]) == 42)
    }

    @Test("the feefilter floor clamps every source from below")
    func floor() {
        #expect(FeePolicy.resolve(priority: .low, floorSatPerVByte: 3.5) == 3.5)
        #expect(FeePolicy.resolve(priority: .low, override: 1, floorSatPerVByte: 2) == 2)
        #expect(FeePolicy.resolve(observed: [10], floorSatPerVByte: 1) == 10) // above floor: untouched
    }

    @Test("an embedder estimate outranks the presets and yields to the override")
    func estimate() {
        // Nothing else known: the estimate replaces the preset.
        #expect(FeePolicy.resolve(priority: .high, estimated: 3) == 3)
        // The user override still wins, estimate or no estimate.
        #expect(FeePolicy.resolve(override: 42, estimated: 3) == 42)
        // And the peer floor still clamps it from below.
        #expect(FeePolicy.resolve(estimated: 1, floorSatPerVByte: 3) == 3)
    }

    @Test("an estimate is floored at the observed median, never under it")
    func estimateMedianFloor() {
        // A lowballing or stale estimate cannot price the wallet below the
        // feerates it has itself paid and seen confirm.
        #expect(FeePolicy.resolve(estimated: 2, observed: [8, 10, 12]) == 10)
        // An estimate above the median is the whole point of having one.
        #expect(FeePolicy.resolve(estimated: 20, observed: [8, 10, 12]) == 20)
        // With no samples there is no floor to apply.
        #expect(FeePolicy.resolve(priority: .high, estimated: 2) == 2)
    }

    /// Every input class the callers can actually produce: a gateway serving
    /// junk, a fat-fingered override, a hostile peer's feefilter.
    @Test("an unusable number falls through to the next source",
          arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1e12])
    func unusableInputs(_ bad: Double) {
        #expect(FeePolicy.resolve(priority: .medium, estimated: bad) == 5)
        #expect(FeePolicy.resolve(priority: .medium, override: bad) == 5)
        #expect(FeePolicy.resolve(priority: .medium, observed: [bad]) == 5)
        #expect(FeePolicy.resolve(priority: .medium, floorSatPerVByte: bad) == 5)
        // A usable source beside a junk one is still used.
        #expect(FeePolicy.resolve(priority: .medium, estimated: bad, observed: [7, bad]) == 7)
    }

    /// The band `CoinSelection.select` accepts, asserted at the other end of
    /// the pipe: resolution must not hand it a rate it would refuse.
    @Test("no combination of inputs resolves outside the accepted band",
          arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1e12, 9_999])
    func bandHolds(_ bad: Double) {
        for priority in FeePolicy.Priority.allCases {
            let rate = FeePolicy.resolve(priority: priority, override: bad, estimated: bad,
                                         observed: [bad, bad], floorSatPerVByte: bad)
            #expect(rate.isFinite)
            #expect(rate > 0)
            #expect(rate <= FeePolicy.maximumSatPerVByte)
        }
    }

    /// Discarding rather than clamping is what makes the order a fall-through
    /// instead of a precedence: a junk override does not take the whole
    /// resolution down to the preset with a better-informed number sitting
    /// right beneath it. The cases above drop one source at a time; this is
    /// the pair, which is the shape a real caller has — a stored override from
    /// a text field beside an estimate from a gateway.
    @Test("an unusable override falls through to the estimate, not past it")
    func unusableOverrideFallsThroughToTheEstimate() {
        #expect(FeePolicy.resolve(priority: .medium, override: .nan, estimated: 7) == 7)
        #expect(FeePolicy.resolve(priority: .medium, override: -1, estimated: 7) == 7)
        // The estimate is still floored at the observed median once it is used.
        #expect(FeePolicy.resolve(priority: .medium, override: 0, estimated: 7, observed: [9]) == 9)
        // And with the estimate unusable too, the median — not the preset.
        #expect(FeePolicy.resolve(priority: .medium, override: .infinity, estimated: .nan,
                                  observed: [9]) == 9)
    }

    /// `usable` names a half-open range at the bottom and a closed one at the
    /// top, so the ceiling itself is a legal feerate at every source and the
    /// first representable value above it is not. `CoinSelection` accepts the
    /// same number (`acceptedFeeRateExtremes`), which is the point of the two
    /// gates naming one constant.
    @Test("the fee ceiling is usable at every source and the next value up is not")
    func feeCeilingIsInclusive() {
        let ceiling = FeePolicy.maximumSatPerVByte
        #expect(FeePolicy.resolve(override: ceiling) == ceiling)
        #expect(FeePolicy.resolve(estimated: ceiling) == ceiling)
        #expect(FeePolicy.resolve(observed: [ceiling]) == ceiling)
        #expect(FeePolicy.resolve(floorSatPerVByte: ceiling) == ceiling)

        // One ulp past it, every source is discarded and the preset stands.
        let past = ceiling.nextUp
        #expect(FeePolicy.resolve(priority: .medium, override: past) == 5)
        #expect(FeePolicy.resolve(priority: .medium, estimated: past) == 5)
        #expect(FeePolicy.resolve(priority: .medium, observed: [past]) == 5)
        #expect(FeePolicy.resolve(priority: .medium, floorSatPerVByte: past) == 5)
    }

    @Test("median of observed samples")
    func median() {
        #expect(FeePolicy.median([]) == nil)
        #expect(FeePolicy.median([5]) == 5)
        #expect(FeePolicy.median([1, 9, 3]) == 3)
        #expect(FeePolicy.median([1, 3, 9, 5]) == 4)
    }

    @Test("a peer pool with no connected peers has no floor")
    func poolFloor() async {
        let pool = PeerPool(params: .signet)
        #expect(await pool.feeFilterFloorSatPerVByte() == nil)
    }
}
