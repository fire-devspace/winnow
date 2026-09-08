import Foundation
import P256K
import Testing
import TestSupport
@testable import WalletCore

@Suite("Wallet")
struct WalletTests {
    @Test("create: mnemonic stored, descriptor shape, wallet ID = master fingerprint")
    func create() async throws {
        let keyStore = InMemoryKeyStore()
        let wallet = try makeTestWallet(keyStore: keyStore)
        // The all-zero entropy mnemonic's master fingerprint (BIP32/BIP86 vectors).
        let id = await wallet.id
        #expect(id == "73c5da0a")
        #expect(try keyStore.load(walletID: "73c5da0a") == .mnemonic(testMnemonic))

        let text = await wallet.descriptor.serialized()
        #expect(text.hasPrefix("tr([73c5da0a/86'/1'/0']tpub"))
        #expect(text.contains("/<0;1>/*)#"))
        // The descriptor round-trips through the BIP380 parser.
        let descriptor = await wallet.descriptor
        #expect(try Descriptor(text) == descriptor)
    }

    @Test("failed wallet persistence rolls back the protected key")
    func createPersistenceRollback() throws {
        let keyStore = InMemoryKeyStore()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wallet-create-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidFile = root.appending(path: "wallet.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: invalidFile, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            _ = try Wallet.create(network: .signet, keyStore: keyStore,
                                  storageURL: invalidFile, entropy: testEntropy)
        }
        #expect(throws: KeyStoreError.notFound(walletID: "73c5da0a")) {
            _ = try keyStore.load(walletID: "73c5da0a")
        }
    }

    @Test("address derivation matches BIP86 (incl. the official mainnet vector)")
    func addresses() async throws {
        let master = try testMaster()
        let wallet = try makeTestWallet()
        // Signet: coin type 1 — cross-checked against BitcoinCore's BIP86.
        for index: UInt32 in [0, 1, 7] {
            let internalKey = try BIP86.internalKey(from: master, coinType: 1, change: 0, index: index)
            #expect(try await wallet.address(chain: .receive, index: index)
                == BIP86.address(internalKey: internalKey, hrp: "tb"))
            let changeInternal = try BIP86.internalKey(from: master, coinType: 1, change: 1, index: index)
            #expect(try await wallet.address(chain: .change, index: index)
                == BIP86.address(internalKey: changeInternal, hrp: "tb"))
        }
        // Mainnet: the official BIP86 vector for m/86'/0'/0'/0/0.
        let mainnet = try makeTestWallet(network: .mainnet)
        #expect(try await mainnet.address(chain: .receive, index: 0)
            == TestScripts.bip86FirstMainnetAddress)
    }

    @Test("freshReceiveAddress advances the index; watch list covers the gap window")
    func gapLimit() async throws {
        let wallet = try makeTestWallet()
        #expect(await wallet.nextReceiveIndex == 0)
        let first = try await wallet.freshReceiveAddress()
        #expect(first == (try await wallet.address(chain: .receive, index: 0)))
        #expect(await wallet.nextReceiveIndex == 1)
        // (1 used + 20 lookahead) receive + (0 used + 20 lookahead) change.
        #expect(try await wallet.watchScripts().count == 21 + 20)
    }

    @Test("apply: a matched payment becomes a UTXO + history; a spend shrinks the set")
    func applyMatches() async throws {
        let wallet = try makeTestWallet()
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let funding = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 200_000, scriptPubKey: script),
        ], locktime: 0)
        let effect = try await wallet.apply(match: fakeMatch(height: 100, transactions: [funding]))
        #expect(effect.received.count == 1 && effect.spent.isEmpty)
        #expect(await wallet.balance == 200_000)
        #expect(await wallet.utxos.count == 1)
        #expect(await wallet.history.count == 1)
        #expect(await wallet.history[0].received == 200_000)

        // Spending tx: one of our inputs + payment elsewhere; fee observable.
        let utxo = try #require(await wallet.utxos.first)
        var spend = Transaction(version: 2, inputs: [
            Transaction.Input(previousOutput: utxo.outpoint, scriptSig: Data(), sequence: 0xFFFF_FFFD),
        ], outputs: [
            Transaction.Output(value: 199_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x55, count: 32))),
        ], locktime: 0)
        spend.inputs[0].witness = [Data(repeating: 0, count: 64)] // fake sig for vsize math
        let spendEffect = try await wallet.apply(match: fakeMatch(height: 101, transactions: [spend]))
        #expect(spendEffect.spent.count == 1)
        #expect(await wallet.balance == 0)
        #expect(await wallet.utxos.isEmpty)
        #expect(await wallet.history.count == 2)
        #expect(await wallet.history[1].spent == 200_000)
        #expect(await wallet.history[1].fee == 1_000) // all inputs ours → fee known
        #expect(await wallet.observedFeeRates.count == 1)
    }

    @Test("block application rejects wallet-wide monetary overflow atomically")
    func applyRejectsAggregateOverflow() async throws {
        let wallet = try makeTestWallet()
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let first = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            .init(value: BitcoinAmount.maximum, scriptPubKey: script),
        ], locktime: 0)
        try await wallet.apply(match: fakeMatch(height: 100, transactions: [first]))
        #expect(await wallet.balance == BitcoinAmount.maximum)

        let second = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            .init(value: BitcoinAmount.maximum, scriptPubKey: script),
        ], locktime: 1)
        do {
            _ = try await wallet.apply(match: fakeMatch(height: 101, transactions: [second]))
            Issue.record("a wallet total above Bitcoin's monetary range was accepted")
        } catch let error as WalletError {
            #expect(error == .invalidTransactionAmounts)
        }

        #expect(await wallet.balance == BitcoinAmount.maximum)
        #expect(await wallet.utxos.count == 1)
        #expect(await wallet.history.count == 1)
    }

    @Test("payments beyond the gap-limit window are not detected; inside it, indices advance")
    func gapWindow() async throws {
        let wallet = try makeTestWallet()
        // Index 25 is outside the initial window (0 used + 20 lookahead).
        let outside = try await wallet.scriptPubKey(chain: .receive, index: 25)
        let txOutside = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 5_000, scriptPubKey: outside),
        ], locktime: 0)
        let effect1 = try await wallet.apply(match: fakeMatch(height: 100, transactions: [txOutside]))
        #expect(effect1.received.isEmpty)
        #expect(await wallet.balance == 0)

        // Index 3 is inside the window; the receive index advances past it.
        let inside = try await wallet.scriptPubKey(chain: .receive, index: 3)
        let txInside = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 7_000, scriptPubKey: inside),
        ], locktime: 0)
        let effect2 = try await wallet.apply(match: fakeMatch(height: 101, transactions: [txInside]))
        #expect(effect2.received.count == 1)
        #expect(await wallet.nextReceiveIndex == 4)
        #expect(await wallet.balance == 7_000)
    }

    @Test("coinbase outputs are credited immediately but not spendable until 100 confirmations")
    func coinbaseMaturity() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)], mature: false)
        #expect(await wallet.utxos.first?.isCoinbase == true)
        #expect(await wallet.spendableUtxos.isEmpty)
        #expect(await wallet.balance == 150_000)

        let destination = TestScripts.p2trDestination
        await #expect(throws: CoinSelectionError.noUTXOs) {
            try await wallet.buildSend(
                payments: [Payment(amount: 100_000, scriptPubKey: destination)],
                feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        }

        // 99 confirmations: still immature (tip 198 → 198-100+1 = 99).
        try await wallet.recordScanHeight(199)
        #expect(await wallet.spendableUtxos.isEmpty)
        await #expect(throws: CoinSelectionError.noUTXOs) {
            try await wallet.buildSend(
                payments: [Payment(amount: 100_000, scriptPubKey: destination)],
                feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        }

        try await matureCoinbase(wallet, height: 100)
        #expect(await wallet.spendableUtxos.count == 1)
        let built = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        #expect(built.built.transaction.inputs.count == 1)
    }

    @Test("buildSend leaves wallet state untouched until commit (rollback safety)")
    func buildSendDefersCommit() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let utxosBefore = await wallet.utxos.count
        let changeIndexBefore = await wallet.nextChangeIndex

        let destination = TestScripts.p2trDestination
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })

        // Nothing moved: had broadcast thrown here, no UTXO is stranded.
        #expect(await wallet.balance == 150_000)
        #expect(await wallet.utxos.count == utxosBefore)
        #expect(await wallet.nextChangeIndex == changeIndexBefore)
        #expect(await wallet.history.first { $0.txid == prepared.built.transaction.txid } == nil)

        // commit applies exactly the selection the old send() did.
        try await wallet.commit(prepared)
        #expect(await wallet.utxos.count == 1) // 150k spent, pending change in
        #expect(await wallet.balance == prepared.built.changeAmount!)
        #expect(await wallet.history.contains { $0.txid == prepared.built.transaction.txid })
    }

    @Test("signing derives the master key once per send, and every input still verifies")
    func signDerivesMasterOncePerSend() async throws {
        let keyStore = CountingKeyStore()
        let (wallet, _) = try await fundedWallet(keyStore: keyStore, coins: [
            (.receive, 0, 100_000, 100), (.receive, 1, 60_000, 101), (.receive, 2, 40_000, 102),
        ])
        let loadsBefore = keyStore.loads

        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 180_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })

        // Three inputs, one KeyStore read: the master key is derived for the
        // signing operation, not once for each input it signs.
        #expect(prepared.built.transaction.inputs.count == 3)
        #expect(keyStore.loads - loadsBefore == 1)

        // The shared master still yields each input's own key: every witness
        // verifies against the output key its scriptPubKey commits to.
        let signed = prepared.built.transaction
        let spentOutputs = try prepared.built.psbt.spentOutputs()
        for index in signed.inputs.indices {
            let sighash = try SighashBIP341.sighash(tx: signed, inputIndex: index,
                                                    spentOutputs: spentOutputs, hashType: .default)
            let outputKey = P256K.Schnorr.XonlyKey(
                dataRepresentation: spentOutputs[index].scriptPubKey.suffix(32))
            let signature = try P256K.Schnorr.SchnorrSignature(
                dataRepresentation: signed.inputs[index].witness[0])
            var message = [UInt8](sighash)
            #expect(outputKey.isValid(signature, for: &message), "input \(index) must verify")
        }
    }

    /// The replacement path signs through the same `sign(transaction:...)`,
    /// so it gets the same one-derivation-per-operation guarantee — and it is
    /// the path where the cost was doubled, because a bumped send re-signs
    /// every input the original one did. Three inputs, so a per-input
    /// derivation would read the store three times and not one.
    @Test("a fee bump derives the master key once, not once per input it re-signs")
    func feeBumpDerivesMasterOncePerSigning() async throws {
        let keyStore = CountingKeyStore()
        let (wallet, _) = try await fundedWallet(keyStore: keyStore, coins: [
            (.receive, 0, 100_000, 100), (.receive, 1, 60_000, 101), (.receive, 2, 40_000, 102),
        ])
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 180_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let txid = original.built.transaction.txid
        let rate = try await wallet.pendingFeeRate(txid: txid)

        let loadsBefore = keyStore.loads
        let replacement = try await wallet.buildFeeBump(txid: txid, feeRateSatPerVByte: rate + 1)
        #expect(replacement.built.transaction.inputs.count == 3)
        #expect(keyStore.loads - loadsBefore == 1)

        // And the replacement is still a valid, committable transaction: the
        // shared master produced each input's own key, not one key three times.
        try await wallet.commitFeeBump(replacement)
        #expect(await wallet.history.contains { $0.txid == replacement.built.transaction.txid })
    }

    @Test("a signed transaction past the standard size limit is refused after signing")
    func standardSizeCeiling() throws {
        let output = Transaction.Output(value: 100_000, scriptPubKey: TestScripts.p2trDestination)
        func signed(inputs: Int) -> Transaction {
            // A P2TR key-path witness: one 64-byte SIGHASH_DEFAULT signature.
            Transaction(version: 2, inputs: (0 ..< inputs).map {
                Transaction.Input(
                    previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32),
                                                         vout: UInt32($0)),
                    scriptSig: Data(), sequence: TransactionBuilder.defaultSequence,
                    witness: [Data(repeating: 0x22, count: 64)])
            }, outputs: [output], locktime: 0)
        }
        var pastCeiling = 1
        while TransactionBuilder.signedVSize(inputCount: pastCeiling, outputs: [output])
            <= TransactionBuilder.maximumStandardVSize { pastCeiling += 1 }

        // The guard measures the signed bytes where coin selection estimates
        // them. For the key-path spends this wallet makes the two agree
        // exactly, which is why the boundary is built here rather than sent
        // through buildSend — selection refuses it one step earlier.
        let fits = signed(inputs: pastCeiling - 1)
        #expect(TransactionBuilder.vsize(of: fits)
            == TransactionBuilder.signedVSize(inputCount: pastCeiling - 1, outputs: [output]))
        #expect(throws: Never.self) { try Wallet.checkStandardSize(fits) }

        let over = signed(inputs: pastCeiling)
        let vsize = TransactionBuilder.vsize(of: over)
        #expect(vsize > TransactionBuilder.maximumStandardVSize)
        #expect(throws: WalletError.transactionTooLarge(
            vsize: vsize, limit: TransactionBuilder.maximumStandardVSize)) {
            try Wallet.checkStandardSize(over)
        }
    }

    /// The same ceiling on the other path that signs.
    ///
    /// `buildSend` measures its signed bytes and coin selection refuses the
    /// estimate before that, so nothing in this build can produce the pending
    /// send this starts from. A build that predates either check could, and
    /// its transaction is still in the state file — so the state file is
    /// written the way that build would have left it: a pending transaction
    /// already past the ceiling, with its change output still ours to
    /// respend. A replacement rebuilt from it is the same size, and
    /// `commitFeeBump` behind it marks every input spent for a transaction no
    /// peer will relay.
    @Test("a fee bump refuses a replacement past the standard size limit")
    func feeBumpRefusesAnOversizedReplacement() async throws {
        let url = tempFileURL("oversized-pending-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 100_000_000, 100)])
        let coin = try #require(await wallet.utxos.first)
        let changeScript = try await wallet.scriptPubKey(chain: .change, index: 0)

        // One input and enough recipients to clear the ceiling: a P2TR output
        // is 43 bytes, so ~2,400 of them put the vsize past 100,000.
        let payments = (0 ..< 2_400).map { _ in
            Payment(amount: 1_000, scriptPubKey: TestScripts.p2trDestination)
        }
        let changeOutputIndex = payments.count
        let oversized = try TransactionBuilder.build(
            inputs: [coin.outpoint], payments: payments,
            change: Payment(amount: 90_000_000, scriptPubKey: changeScript),
            changePosition: changeOutputIndex)
        #expect(TransactionBuilder.signedVSize(inputCount: 1, outputs: oversized.outputs)
            > TransactionBuilder.maximumStandardVSize, "the fixture must be over the ceiling")

        // The state an older build would have persisted: the input spent by a
        // send still in flight, its change live, and the exact transaction
        // kept so a replacement can be rebuilt from it.
        var state = try JSONDecoder().decode(WalletState.self, from: Data(contentsOf: url))
        var spentFunding = coin
        spentFunding.spent = WalletUTXO.SpentMarker(spentBy: oversized.txid, height: nil)
        state.allUtxos = [spentFunding,
                          WalletUTXO(txid: oversized.txid, vout: UInt32(changeOutputIndex),
                                     amount: 90_000_000, scriptPubKey: changeScript,
                                     chain: .change, index: 0, height: 0)]
        state.nextChangeIndex = 1
        state.pendingSends = [PendingSend(
            rawTransaction: oversized.serialized(includeWitness: true), selected: [coin],
            changeIndex: 0, changeOutputIndex: UInt32(changeOutputIndex), fee: 1_000)]
        try JSONEncoder().encode(state).write(to: url, options: .atomic)

        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        let txid = oversized.txid
        #expect(await reopened.feeBumpableTxids == [txid], "the fixture is bumpable to begin with")
        let rate = try await reopened.pendingFeeRate(txid: txid)

        var thrown: (any Error)?
        do {
            _ = try await reopened.buildFeeBump(txid: txid, feeRateSatPerVByte: rate + 1)
        } catch {
            thrown = error
        }
        guard case let .transactionTooLarge(vsize, limit)? = thrown as? WalletError else {
            Issue.record("expected transactionTooLarge, got \(String(describing: thrown))")
            return
        }
        #expect(limit == TransactionBuilder.maximumStandardVSize)
        #expect(vsize > limit)
        // Refused before anything moved, like every other build failure here.
        #expect(await reopened.feeBumpableTxids == [txid])
        #expect(await reopened.balance == 90_000_000)
    }

    @Test("fee bump keeps inputs/payments, satisfies BIP125 fees, signs, and persists")
    func feeBump() async throws {
        let url = tempFileURL("wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                coins: [(.receive, 0, 150_000, 100)])
        let fundingScript = try await wallet.scriptPubKey(chain: .receive, index: 0)

        let destination = TestScripts.p2trDestination
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let originalTx = original.built.transaction
        let originalBalance = await wallet.balance
        let currentRate = try await wallet.pendingFeeRate(txid: originalTx.txid)

        do {
            _ = try await wallet.previewFeeBump(txid: originalTx.txid,
                                                feeRateSatPerVByte: currentRate)
            Issue.record("an equal feerate must not build a replacement")
        } catch let error as FeeBumpError {
            guard case .feeRateNotHigher = error else {
                Issue.record("unexpected fee-bump error: \(error)")
                return
            }
        }

        // A tiny requested increase is intentionally below BIP125 rule 4;
        // the builder must raise the actual fee by one replacement vbyte.
        let preview = try await wallet.previewFeeBump(
            txid: originalTx.txid, feeRateSatPerVByte: currentRate + 0.000_1)
        let replacement = try await wallet.buildFeeBump(
            txid: originalTx.txid, feeRateSatPerVByte: currentRate + 0.000_1)
        let replacementTx = replacement.built.transaction
        let replacementVSize = TransactionBuilder.vsize(of: replacementTx)
        #expect(replacement.built.fee >= original.built.fee + Int64(replacementVSize))
        #expect(preview.fee == replacement.built.fee)
        #expect(preview.feeRateSatPerVByte > currentRate)
        #expect(preview.authorizes(replacement.built))

        var changedFee = replacement.built
        changedFee.fee += 1
        #expect(!preview.authorizes(changedFee))

        var changedOutput = replacement.built
        changedOutput.transaction.outputs[0].value -= 1
        #expect(!preview.authorizes(changedOutput))

        var changedInput = replacement.built
        changedInput.transaction.inputs[0].previousOutput.vout += 1
        #expect(!preview.authorizes(changedInput))

        var changedSequence = replacement.built
        changedSequence.transaction.inputs[0].sequence -= 1
        #expect(!preview.authorizes(changedSequence))
        #expect(replacementTx.inputs.map(\.previousOutput) == originalTx.inputs.map(\.previousOutput))
        #expect(replacementTx.outputs.contains { $0.value == 100_000 && $0.scriptPubKey == destination })
        #expect(replacement.built.changeAmount! < original.built.changeAmount!)

        // PSBT signing uses the exact original prevout metadata.
        let sighash = try SighashBIP341.sighash(
            tx: replacementTx, inputIndex: 0,
            spentOutputs: [SighashBIP341.SpentOutput(amount: 150_000, scriptPubKey: fundingScript)])
        let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: fundingScript.suffix(32))
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: replacementTx.inputs[0].witness[0])
        var message = [UInt8](sighash)
        #expect(outputKey.isValid(signature, for: &message))

        // Build is rollback-safe; commit swaps pending change and history.
        #expect(await wallet.history.first { $0.txid == originalTx.txid }?.replacedBy == nil)
        try await wallet.commitFeeBump(replacement)
        #expect(await wallet.history.first { $0.txid == originalTx.txid }?.replacedBy == replacementTx.txid)
        #expect(await wallet.history.first { $0.txid == replacementTx.txid }?.height == 0)
        #expect(await wallet.balance == originalBalance - (replacement.built.fee - original.built.fee))
        #expect(await wallet.nextChangeIndex == 1)

        // Exact prevouts/raw tx survive relaunch, so a second bump can be built.
        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        #expect(await reopened.feeBumpableTxids == [replacementTx.txid])
        let reopenedRate = try await reopened.pendingFeeRate(txid: replacementTx.txid)
        _ = try await reopened.buildFeeBump(txid: replacementTx.txid,
                                            feeRateSatPerVByte: reopenedRate + 1)
    }

    @Test("same-input bump refuses a changeless send")
    func feeBumpNeedsChange() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 100_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x88, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 99_778, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        #expect(original.built.changeAmount == nil)
        try await wallet.commit(original)
        #expect(await wallet.feeBumpableTxids.isEmpty)
        do {
            _ = try await wallet.buildFeeBump(txid: original.built.transaction.txid,
                                              feeRateSatPerVByte: 5)
            Issue.record("a changeless same-input spend cannot be bumped")
        } catch let error as FeeBumpError {
            #expect(error == .noChangeOutput)
        }
    }

    @Test("a parent whose pending change was spent by a child refuses a bump")
    func feeBumpRefusesSpentChange() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x55, count: 32))
        let parent = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(parent)

        // The only spendable UTXO is now the parent's height-0 change, so the
        // child spend is forced onto it.
        let child = try await wallet.buildSend(
            payments: [Payment(amount: 20_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        #expect(child.built.transaction.inputs.contains {
            $0.previousOutput.txid == parent.built.transaction.txid
        })
        try await wallet.commit(child)

        // The parent's change has left the UTXO set; a same-input replacement
        // of the parent would orphan the committed child.
        #expect(!(await wallet.feeBumpableTxids).contains(parent.built.transaction.txid))
        do {
            _ = try await wallet.buildFeeBump(txid: parent.built.transaction.txid,
                                              feeRateSatPerVByte: 5)
            Issue.record("bumping the parent would orphan the committed child spend")
        } catch let error as FeeBumpError {
            #expect(error == .changeAlreadySpent)
        }
    }

    @Test("fee bump removes change when the higher-fee remainder becomes dust")
    func feeBumpDropsDustChange() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 101_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x66, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        let originalChange = try #require(original.built.changeAmount)
        let changeScript = try await wallet.scriptPubKey(chain: .change, index: 0)
        #expect(originalChange >= CoinSelection.dustThreshold(scriptPubKey: changeScript))
        try await wallet.commit(original)

        let replacement = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 7)
        #expect(replacement.built.changeAmount == nil)
        #expect(replacement.built.transaction.outputs.count == 1)
        #expect(replacement.built.transaction.outputs[0].value == 100_000)
        #expect(replacement.built.fee == 1_000)
        try await wallet.commitFeeBump(replacement)
        #expect(await wallet.balance == 0)
        #expect(await wallet.feeBumpableTxids.isEmpty)
    }

    @Test("confirmation chooses one replacement-chain member without double-counting change")
    func feeBumpConfirmationRace() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let replacement = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 5)
        try await wallet.commitFeeBump(replacement)

        // The original can still win before the replacement propagates. Its
        // confirmation discards the descendant row/change and restores only
        // the original change as confirmed.
        let effect = try await wallet.apply(match: fakeMatch(
            height: 150, transactions: [original.built.transaction]))
        #expect(effect.discardedReplacements == [replacement.built.transaction.txid])
        let history = await wallet.history
        #expect(history.first { $0.txid == original.built.transaction.txid }?.height == 150)
        #expect(history.first { $0.txid == original.built.transaction.txid }?.replacedBy == nil)
        #expect(history.first { $0.txid == replacement.built.transaction.txid } == nil)
        #expect(await wallet.utxos.contains {
            $0.txid == original.built.transaction.txid && $0.height == 150
        })
        #expect(!(await wallet.utxos).contains { $0.txid == replacement.built.transaction.txid })
    }

    @Test("a middle replacement confirming discards only its later descendants")
    func feeBumpMiddleConfirmation() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x66, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let first = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 5)
        try await wallet.commitFeeBump(first)
        let second = try await wallet.buildFeeBump(
            txid: first.built.transaction.txid, feeRateSatPerVByte: 8)
        try await wallet.commitFeeBump(second)

        let effect = try await wallet.apply(match: fakeMatch(
            height: 150, transactions: [first.built.transaction]))
        #expect(effect.discardedReplacements == [second.built.transaction.txid])
        let history = await wallet.history
        #expect(history.first { $0.txid == original.built.transaction.txid }?.replacedBy
                == first.built.transaction.txid)
        #expect(history.first { $0.txid == first.built.transaction.txid }?.height == 150)
        #expect(history.first { $0.txid == first.built.transaction.txid }?.replacedBy == nil)
        #expect(history.first { $0.txid == second.built.transaction.txid } == nil)
        #expect(await wallet.utxos.contains {
            $0.txid == first.built.transaction.txid && $0.height == 150
        })
        #expect(!(await wallet.utxos).contains { $0.txid == second.built.transaction.txid })
        #expect(await wallet.feeBumpableTxids.isEmpty)
    }

    @Test("an already-relayed replacement confirms safely if its state commit failed")
    func uncommittedFeeBumpConfirmation() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = Data([0x51, 0x20] + repeatElement(0x44, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let replacement = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 5)

        // Model the broadcast-success / persistence-failure boundary by
        // confirming the built replacement without committing its state swap.
        let effect = try await wallet.apply(match: fakeMatch(
            height: 150, transactions: [replacement.built.transaction]))
        #expect(effect.discardedReplacements == [original.built.transaction.txid])
        #expect(await wallet.history.first {
            $0.txid == original.built.transaction.txid
        }?.replacedBy == replacement.built.transaction.txid)
        let replacementEntry = try await #require(wallet.history.first {
            $0.txid == replacement.built.transaction.txid
        })
        #expect(replacementEntry.height == 150)
        #expect(replacementEntry.spent == 150_000)
        #expect(replacementEntry.fee == replacement.built.fee)
        let replacementChange = try #require(replacement.built.changeAmount)
        #expect(await wallet.balance == replacementChange)
        #expect(await wallet.feeBumpableTxids.isEmpty)
        #expect(!(await wallet.utxos).contains { $0.txid == original.built.transaction.txid })
    }

    @Test("a reordered-input replacement reconciles the losing pending send")
    func reorderedInputReplacementConfirmation() async throws {
        let wallet = try makeTestWallet()
        let fundingScript = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let funding = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 80_000, scriptPubKey: fundingScript),
            Transaction.Output(value: 80_000, scriptPubKey: fundingScript),
        ], locktime: 0)
        try await wallet.apply(match: fakeMatch(height: 100, transactions: [funding]))
        try await matureCoinbase(wallet, height: 100)
        let destination = Data([0x51, 0x20] + repeatElement(0x33, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 120_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        #expect(original.built.transaction.inputs.count == 2)
        try await wallet.commit(original)

        let prepared = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 5)
        let built = prepared.built.transaction
        let reordered = Transaction(version: built.version, inputs: Array(built.inputs.reversed()),
                                    outputs: built.outputs, locktime: built.locktime)
        let effect = try await wallet.apply(match: fakeMatch(
            height: 150, transactions: [reordered]))

        #expect(effect.discardedReplacements == [original.built.transaction.txid])
        #expect(await wallet.history.first {
            $0.txid == original.built.transaction.txid
        }?.replacedBy == reordered.txid)
        #expect(await wallet.history.first { $0.txid == reordered.txid }?.height == 150)
        #expect(!(await wallet.utxos).contains { $0.txid == original.built.transaction.txid })
        #expect(await wallet.utxos.contains { $0.txid == reordered.txid && $0.height == 150 })
        #expect(await wallet.feeBumpableTxids.isEmpty)
    }

    @Test("persistence: state round-trips through Wallet.open")
    func persistence() async throws {
        let url = tempFileURL("wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let wallet = try makeTestWallet(storageURL: url, keyStore: keyStore)
        _ = try await wallet.freshReceiveAddress()
        try await fund(wallet, amount: 42_000, height: 100)

        let reopened = try await Wallet.open(storageURL: url, keyStore: keyStore)
        let reopenedID = await reopened.id
        #expect(reopenedID == "73c5da0a")
        #expect(await reopened.balance == 42_000)
        #expect(await reopened.nextReceiveIndex == 1)
        #expect(await reopened.history.count == 1)
        let reopenedDescriptor = await reopened.descriptor
        let originalDescriptor = await wallet.descriptor
        #expect(reopenedDescriptor == originalDescriptor)
    }

    @Test("corrupt persisted coin totals fail closed instead of trapping balance")
    func corruptPersistedAmounts() async throws {
        let url = tempFileURL("corrupt-amount-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let wallet = try makeTestWallet(storageURL: url, keyStore: keyStore)
        try await fund(wallet, amount: 42_000, height: 100)

        let data = try Data(contentsOf: url)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var coins = try #require(json["utxos"] as? [[String: Any]])
        coins[0]["amount"] = BitcoinAmount.maximum
        var second = coins[0]
        second["vout"] = 1
        coins.append(second)
        json["utxos"] = coins
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        #expect(throws: (any Error).self) {
            _ = try Wallet.open(storageURL: url, keyStore: keyStore)
        }
    }

    @Test("invalid block amounts are rejected atomically before wallet mutation")
    func invalidBlockAmounts() async throws {
        let wallet = try makeTestWallet()
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let valid = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 42_000, scriptPubKey: script),
        ], locktime: 0)
        let invalid = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: BitcoinAmount.maximum, scriptPubKey: script),
            Transaction.Output(value: 1, scriptPubKey: Data([0x51])),
        ], locktime: 0)

        await #expect(throws: WalletError.invalidTransactionAmounts) {
            _ = try await wallet.apply(match: fakeMatch(
                height: 100, transactions: [valid, invalid]))
        }
        #expect(await wallet.balance == 0)
        #expect(await wallet.history.isEmpty)
    }

    @Test("zero-value watched outputs are ignored without wedging later blocks")
    func zeroValueWatchedOutputDoesNotWedgeScan() async throws {
        let wallet = try makeTestWallet()
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let zero = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 0, scriptPubKey: script),
        ], locktime: 0)

        let effect = try await wallet.apply(match: fakeMatch(height: 100, transactions: [zero]))
        #expect(effect.received.isEmpty)
        #expect(await wallet.balance == 0)
        #expect(await wallet.utxos.isEmpty)
        #expect(await wallet.history.isEmpty)
        #expect(await wallet.nextReceiveIndex == 0)

        let positive = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 42_000, scriptPubKey: script),
        ], locktime: 0)
        _ = try await wallet.apply(match: fakeMatch(height: 101, transactions: [positive]))
        #expect(await wallet.balance == 42_000)
        #expect(await wallet.nextReceiveIndex == 1)
    }

    @Test("wallet state from before fee-bump metadata remains readable")
    func legacyPersistence() async throws {
        let url = tempFileURL("legacy-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let wallet = try makeTestWallet(storageURL: url, keyStore: keyStore)
        _ = try await wallet.freshReceiveAddress()

        let data = try Data(contentsOf: url)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "pendingSends")
        json.removeValue(forKey: "observedFeeRates")
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        #expect(await reopened.nextReceiveIndex == 1)
        #expect(await reopened.feeBumpableTxids.isEmpty)
        #expect(await reopened.observedFeeRates.isEmpty)
    }

    @Test("a failed persist on the first send leaves memory and disk in agreement")
    func commitPersistFailureLeavesStateUntouched() async throws {
        let url = tempFileURL("commit-rollback-wallet.json")
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                coins: [(.receive, 0, 150_000, 100)])
        let destination = TestScripts.p2trDestination
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)], feeRateSatPerVByte: 2,
            chainTip: testChainTip, randomness: { 0.5 })
        let changeIndexBefore = await wallet.nextChangeIndex

        // The state file becomes unwritable: a directory now sits at its path.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) { try await wallet.commit(prepared) }
        // Nothing moved in memory either: the coin is still spendable, no
        // change row or history entry exists, and no input is reserved.
        #expect(await wallet.balance == 150_000)
        #expect(await wallet.utxos.count == 1)
        #expect(await wallet.allUtxos.allSatisfy { !$0.isSpent })
        #expect(await wallet.nextChangeIndex == changeIndexBefore)
        #expect(await wallet.history.contains { $0.txid == prepared.built.transaction.txid } == false)
    }

    @Test("a committed send records where it paid and which output was change")
    func sendRecordsItsOutputs() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = TestScripts.p2trDestination
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        let signed = prepared.built.transaction
        let paid = try #require(signed.outputs.firstIndex { $0.scriptPubKey == destination })
        let change = try #require(signed.outputs.firstIndex { $0.scriptPubKey != destination })
        let outputs = try #require(await wallet.history.first { $0.txid == signed.txid }?.outputs)
        #expect(outputs.external == [HistoryEntry.ExternalOutput(
            vout: UInt32(paid), amount: 100_000, scriptPubKey: destination)])
        #expect(outputs.change == [UInt32(change)])

        // Confirmation retires the pending send, which used to be the only
        // record of the destination. The entry keeps it.
        try await wallet.apply(match: fakeMatch(height: 150, transactions: [signed]))
        let confirmed = try #require(await wallet.history.first { $0.txid == signed.txid })
        #expect(confirmed.height == 150)
        #expect(await wallet.feeBumpableTxids.isEmpty)
        #expect(confirmed.outputs == outputs)
    }

    @Test("a send to one of our own addresses is neither an external output nor change")
    func sendToOwnAddressIsNotExternal() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let ours = try await wallet.scriptPubKey(chain: .receive, index: 1)
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: ours)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        let signed = prepared.built.transaction
        #expect(signed.outputs.count == 2)
        let outputs = try #require(await wallet.history.first { $0.txid == signed.txid }?.outputs)
        #expect(outputs.external.isEmpty)
        #expect(outputs.change.count == 1)
    }

    @Test("a fee-bumped replacement records the outputs it pays")
    func feeBumpRecordsItsOutputs() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let destination = TestScripts.p2trDestination
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(original)
        let originalTxid = original.built.transaction.txid
        let rate = try await wallet.pendingFeeRate(txid: originalTxid)
        let replacement = try await wallet.buildFeeBump(txid: originalTxid,
                                                        feeRateSatPerVByte: rate + 1)
        try await wallet.commitFeeBump(replacement)

        let signed = replacement.built.transaction
        let outputs = try #require(await wallet.history.first { $0.txid == signed.txid }?.outputs)
        #expect(outputs.external.map(\.amount) == [100_000])
        #expect(outputs.external.first?.scriptPubKey == destination)
        // Its change is smaller than the original's and still ours.
        #expect(outputs.change.count == 1)
    }

    @Test("recorded outputs round-trip through the state file")
    func recordedOutputsRoundTrip() async throws {
        let url = tempFileURL("history-outputs-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        // The script goes to disk as hex, like a coin's.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let json = try #require(object as? [String: Any])
        let entries = try #require(json["history"] as? [[String: Any]])
        let recorded = try #require(entries.last?["outputs"] as? [String: Any])
        let external = try #require(recorded["external"] as? [[String: Any]])
        #expect(external.first?["scriptPubKey"] as? String == TestScripts.p2trDestination.hex)

        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        let entry = try #require(await reopened.history.first {
            $0.txid == prepared.built.transaction.txid
        })
        #expect(entry.outputs == (await wallet.history.last?.outputs))
        #expect(entry.outputs?.external.first?.amount == 100_000)
    }

    @Test("wallet state written before outputs were recorded remains readable")
    func historyWithoutRecordedOutputs() async throws {
        let url = tempFileURL("legacy-history-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        // Rewrite the file in the shape a previous version wrote: every other
        // field identical, the key simply absent.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var json = try #require(object as? [String: Any])
        json["history"] = try #require(json["history"] as? [[String: Any]]).map { entry in
            var older = entry
            older.removeValue(forKey: "outputs")
            return older
        }
        let older = try JSONSerialization.data(withJSONObject: json)
        #expect(!String(decoding: older, as: UTF8.self).contains("outputs"))
        try older.write(to: url, options: .atomic)

        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        let entry = try #require(await reopened.history.first {
            $0.txid == prepared.built.transaction.txid
        })
        // Not known, which is not the same as a send that paid nobody.
        #expect(entry.outputs == nil)
        // Everything the older shape did carry still loads.
        #expect(entry.spent == 150_000)
        #expect(entry.fee == prepared.built.fee)
        #expect(await reopened.feeBumpableTxids == [prepared.built.transaction.txid])
    }

    // MARK: Review follow-ups: the breakdown's own decoding and validation

    /// `Outputs` had the one shape in this patch that did not follow the
    /// file's `decodeIfPresent ?? default` idiom: the defaults lived on
    /// `init` only, which Swift's synthesized `init(from:)` ignores, so an
    /// entry carrying `external` and no `change` threw `keyNotFound` and
    /// `Wallet.open` refused the whole file. No writer here produces that
    /// shape, so nothing was bricked — but the argument one level up is that
    /// a missing key means "not known", and one level down it meant fatal.
    @Test("a recorded breakdown missing one of its two lists decodes as empty")
    func outputsDecodeWithAMissingList() async throws {
        let url = tempFileURL("partial-outputs-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        let good = try Data(contentsOf: url)

        // Drop `change` from the recorded breakdown, keeping everything else.
        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var without = outputs
            without.removeValue(forKey: "change")
            return without
        }
        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        let entry = try #require(await reopened.history.first {
            $0.txid == prepared.built.transaction.txid
        })
        let outputs = try #require(entry.outputs, "the breakdown still decodes")
        #expect(outputs.change.isEmpty, "an absent list is an empty one")
        #expect(outputs.external.count == 1, "the list that is present is unchanged")

        // And the mirror: `external` absent rather than `change`, from the
        // file as it was written rather than from the one just edited.
        try good.write(to: url, options: .atomic)
        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var without = outputs
            without.removeValue(forKey: "external")
            return without
        }
        let mirroredWallet = try Wallet.open(storageURL: url, keyStore: keyStore)
        let mirrored = try #require(await mirroredWallet.history.first {
            $0.txid == prepared.built.transaction.txid
        }?.outputs)
        #expect(mirrored.external.isEmpty)
        #expect(mirrored.change.count == 1)
    }

    /// The hostile-input guard bounded every external amount and left the
    /// vouts beside them unchecked, so a breakdown could claim one vout was
    /// both ours and a stranger's, or list change out of the ascending order
    /// its own doc promises. Nothing reads `outputs` for a money decision, so
    /// this is a self-consistency rule rather than a spend hazard — but half a
    /// field validated is not what the guard is for.
    @Test("a self-contradictory recorded breakdown is refused at load")
    func inconsistentOutputsAreRefused() async throws {
        let url = tempFileURL("inconsistent-outputs-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        let good = try Data(contentsOf: url)

        // Change claiming a vout the external list already claims: one output
        // recorded as both ours and a stranger's.
        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var contradictory = outputs
            let external = (outputs["external"] as? [[String: Any]]) ?? []
            contradictory["change"] = external.compactMap { $0["vout"] as? NSNumber }
            return contradictory
        }
        #expect(throws: (any Error).self) { try Wallet.open(storageURL: url, keyStore: keyStore) }

        // Change out of ascending order, which the doc promises and nothing
        // enforced.
        try good.write(to: url, options: .atomic)
        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var descending = outputs
            descending["change"] = [7, 3]
            return descending
        }
        #expect(throws: (any Error).self) { try Wallet.open(storageURL: url, keyStore: keyStore) }

        // A duplicate is not ascending either.
        try good.write(to: url, options: .atomic)
        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var duplicated = outputs
            duplicated["change"] = [3, 3]
            return duplicated
        }
        #expect(throws: (any Error).self) { try Wallet.open(storageURL: url, keyStore: keyStore) }

        // The unmodified file is the control: it loads.
        try good.write(to: url, options: .atomic)
        #expect(throws: Never.self) { try Wallet.open(storageURL: url, keyStore: keyStore) }
    }

    /// The same rule on the other list, which it was missing.
    ///
    /// `change` was held to strict ascending order and `external` to nothing
    /// but disjointness, so a breakdown could name one vout twice — two
    /// amounts and two scripts for a single output, and a reader has to pick
    /// one — or list its outputs in an order the transaction does not have,
    /// which is what "in transaction order" promises and what makes a vout
    /// checkable against the transaction it names.
    ///
    /// The three cases below are the same two entries every time, at vouts
    /// this transaction's change does not use, so what is being judged is the
    /// order and nothing else: disjointness cannot be the reason any of them
    /// is refused, and the ascending pair is the control that loads.
    @Test("recorded external outputs must be ascending and unique",
          arguments: [([8, 8], false), ([9, 8], false), ([8, 9], true)])
    func externalVoutsMustAscend(vouts: [Int], loads: Bool) async throws {
        let url = tempFileURL("external-order-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var reordered = outputs
            let template = try! #require((outputs["external"] as? [[String: Any]])?.first)
            reordered["external"] = vouts.map { vout -> [String: Any] in
                var entry = template
                entry["vout"] = NSNumber(value: vout)
                return entry
            }
            return reordered
        }
        if loads {
            #expect(throws: Never.self) { try Wallet.open(storageURL: url, keyStore: keyStore) }
        } else {
            #expect(throws: (any Error).self) { try Wallet.open(storageURL: url, keyStore: keyStore) }
        }
    }

    /// `applyOutputs` skips a zero-value output because it is not a coin;
    /// `classifyOutputs` used to record one anyway, so a 0-sat output paying a
    /// watched change script would appear in `change` while being absent from
    /// `allUtxos` — the two paths disagreeing about the same transaction,
    /// which the doc comment says they must not. Unreachable through
    /// `buildSend` (the builder refuses an empty script and selection applies
    /// the dust rule), so the transaction is classified directly.
    @Test("a zero-value output is in neither list, as it is in neither coin set")
    func zeroValueOutputsAreNotClassified() async throws {
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 150_000, 100)])
        let ourChange = try await wallet.scriptPubKey(chain: .change, index: 0)
        let stranger = TestScripts.p2trDestination
        let transaction = Transaction(
            version: 2,
            inputs: [Transaction.Input(
                previousOutput: Transaction.Outpoint(txid: Data(repeating: 9, count: 32), vout: 0),
                scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [Transaction.Output(value: 0, scriptPubKey: stranger),
                      Transaction.Output(value: 0, scriptPubKey: ourChange),
                      Transaction.Output(value: 50_000, scriptPubKey: stranger),
                      Transaction.Output(value: 90_000, scriptPubKey: ourChange)],
            locktime: 0)

        let outputs = try await wallet.classifyOutputs(of: transaction)
        #expect(outputs.external.map(\.vout) == [2], "the 0-sat payment out is not money leaving")
        #expect(outputs.external.map(\.amount) == [50_000])
        #expect(outputs.change == [3], "the 0-sat change output is not a coin, so it is not change")
    }

    /// The other half of the hostile-input guard on a breakdown. Its vouts are
    /// checked for self-consistency (`inconsistentOutputsAreRefused`); its
    /// amounts are held to the monetary range the entry's own `received`,
    /// `spent` and `fee` are held to. An external amount is the one number in
    /// the breakdown a renderer would show as money, so a state file claiming
    /// a send paid out more than exists — or a negative amount — must not
    /// load at all.
    @Test("a recorded external amount outside the monetary range is refused at load",
          arguments: [BitcoinAmount.maximum + 1, -1])
    func externalAmountOutOfRangeIsRefused(_ amount: Int64) async throws {
        let url = tempFileURL("hostile-amount-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        // The file as written loads, so the refusal below is the edit's doing.
        #expect(throws: Never.self) { try Wallet.open(storageURL: url, keyStore: keyStore) }

        try Self.rewriteLastEntryOutputs(in: url) { outputs in
            var hostile = outputs
            var external = (outputs["external"] as? [[String: Any]]) ?? []
            var first = external[0]
            first["amount"] = NSNumber(value: amount)
            external[0] = first
            hostile["external"] = external
            return hostile
        }
        #expect(throws: (any Error).self) { try Wallet.open(storageURL: url, keyStore: keyStore) }
    }

    /// `ExternalOutput` carries the locking script rather than an address, and
    /// a script goes to disk as hex like a coin's. `Data(hex:)` answers nil on
    /// anything that is not hex, so decoding has to turn that into a decoding
    /// error rather than a nil script — a breakdown naming an unreadable
    /// script is not one to load half of.
    @Test("a recorded external script that is not hex is refused at load")
    func externalScriptBadHexIsRefused() async throws {
        let url = tempFileURL("bad-script-hex-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        let good = try Data(contentsOf: url)

        for bad in ["zz", "5120ff0"] { // not hex at all; odd-length hex
            try good.write(to: url, options: .atomic)
            try Self.rewriteLastEntryOutputs(in: url) { outputs in
                var corrupt = outputs
                var external = (outputs["external"] as? [[String: Any]]) ?? []
                var first = external[0]
                first["scriptPubKey"] = bad
                external[0] = first
                corrupt["external"] = external
                return corrupt
            }
            #expect(throws: (any Error).self, "scriptPubKey \(bad)") {
                try Wallet.open(storageURL: url, keyStore: keyStore)
            }
        }
    }

    /// An entry that predates the breakdown is written back exactly as it was
    /// read, which is what `encodeIfPresent` is for: not known must survive a
    /// save, or the first thing a new build does to an old wallet is turn
    /// "not known" into "paid nobody".
    @Test("an entry with no recorded outputs is saved again without the key")
    func legacyEntryIsSavedWithoutTheKey() async throws {
        let url = tempFileURL("legacy-resave-wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore,
                                                 coins: [(.receive, 0, 150_000, 100)])
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)

        // Rewrite in the older shape, then reopen and save through an
        // ordinary state change.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var json = try #require(object as? [String: Any])
        json["history"] = try #require(json["history"] as? [[String: Any]]).map { entry in
            var older = entry
            older.removeValue(forKey: "outputs")
            return older
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)

        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        try await reopened.recordScanHeight(400)
        let saved = try Data(contentsOf: url)
        #expect(!String(decoding: saved, as: UTF8.self).contains("\"outputs\""),
                "a save must not invent a breakdown for an entry that has none")
        let again = try Wallet.open(storageURL: url, keyStore: keyStore)
        let entry = try #require(await again.history.first {
            $0.txid == prepared.built.transaction.txid
        })
        #expect(entry.outputs == nil)
    }

    /// Reads the last history entry's `outputs` object out of a state file,
    /// hands it to `transform`, and writes the file back. The p10 tests each
    /// rewrote the file inline; the follow-ups need several variations of one
    /// edit, so the surgery is in one place.
    private static func rewriteLastEntryOutputs(
        in url: URL, _ transform: ([String: Any]) -> [String: Any]) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var json = try #require(object as? [String: Any])
        var entries = try #require(json["history"] as? [[String: Any]])
        var last = try #require(entries.last)
        last["outputs"] = transform(try #require(last["outputs"] as? [String: Any]))
        entries[entries.count - 1] = last
        json["history"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
    }

}
