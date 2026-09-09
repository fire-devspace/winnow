import Foundation
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// Import bundle (docs/read-side.md §2.7.5): parsing, seeding, and the verify
/// report — including the mismatch cases that must surface, never go silent.
@Suite("Import bundle")
struct ImportBundleTests {
    /// A bundle for the test mnemonic with two claimed UTXOs (receive 0,
    /// receive 1) as of height 500.
    private func makeBundle() async throws -> ImportBundle {
        let wallet = try makeTestWallet(creationHeight: 400)
        func utxoJSON(_ index: UInt32, _ amount: Int64) async throws -> ImportBundle.UTXO {
            try await ImportBundle.UTXO(txid: Data(repeating: UInt8(0x50 + index), count: 32).displayHex,
                                        vout: 0, amount: amount,
                                        scriptPubKey: wallet.scriptPubKey(chain: .receive, index: index).hex,
                                        chain: 0, index: index, height: 490)
        }
        return try await ImportBundle(network: "signet",
                                      descriptor: wallet.descriptor.serialized(),
                                      mnemonic: testMnemonic,
                                      lastKnownHeight: 500,
                                      utxos: [utxoJSON(0, 100_000), utxoJSON(1, 50_000)],
                                      transactions: [ImportBundle.KnownTransaction(
                                          txid: Data(repeating: 0x50, count: 32).displayHex,
                                          height: 490, received: 100_000, spent: 0)])
    }

    @Test("JSON round trip of the documented format")
    func json() throws {
        let json = """
        {
          "version": 1,
          "network": "signet",
          "mnemonic": "\(testMnemonic)",
          "lastKnownHeight": 500,
          "utxos": [{"txid": "\(Data(repeating: 0x51, count: 32).displayHex)", "vout": 0,
                     "amount": 100000, "scriptPubKey": "5120ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                     "chain": 0, "index": 0, "height": 490}],
          "transactions": []
        }
        """
        let bundle = try JSONDecoder().decode(ImportBundle.self, from: Data(json.utf8))
        #expect(bundle.version == 1)
        #expect(bundle.network == "signet")
        #expect(bundle.utxos.count == 1)
        #expect(try JSONDecoder().decode(ImportBundle.self,
                                         from: JSONEncoder().encode(bundle)) == bundle)
    }

    @Test("importing seeds the wallet state; scanning resumes after the bundle height")
    func seeding() async throws {
        let bundle = try await makeBundle()
        let keyStore = InMemoryKeyStore()
        let wallet = try Wallet.importing(bundle, keyStore: keyStore)
        let id = await wallet.id
        #expect(id == "73c5da0a")
        #expect(await wallet.balance == 150_000)
        #expect(await wallet.utxos.count == 2)
        #expect(await wallet.history.count == 1)
        #expect(await wallet.creationHeight == 500)
        #expect(await wallet.nextScanHeight == 501)
        #expect(await wallet.nextReceiveIndex == 2) // past the highest claimed index
        // The secret enables spending.
        #expect(try keyStore.load(walletID: "73c5da0a") == .mnemonic(testMnemonic))

        // V1 remains a supported read format for descriptor-derived funds.
        var legacy = bundle
        legacy.version = 1
        let legacyWallet = try Wallet.importing(legacy, keyStore: InMemoryKeyStore())
        #expect(await legacyWallet.balance == 150_000)
    }

    @Test("fee-replacement history survives export and import")
    func replacementHistory() async throws {
        var bundle = try await makeBundle()
        let replacement = Data(repeating: 0x91, count: 32)
        bundle.transactions[0].replacedBy = replacement.displayHex

        let serialized = try bundle.serialized()
        let decoded = try JSONDecoder().decode(ImportBundle.self, from: Data(serialized.utf8))
        let restored = try Wallet.importing(decoded, keyStore: InMemoryKeyStore())
        #expect(await restored.history[0].replacedBy == replacement)

        bundle.transactions[0].replacedBy = "not-a-txid"
        #expect(throws: WalletError.invalidBundle("bad replacement txid not-a-txid")) {
            _ = try Wallet.importing(bundle, keyStore: InMemoryKeyStore())
        }
    }

    @Test("descriptor/mnemonic disagreement and bad claims are rejected")
    func rejection() async throws {
        let bundle = try await makeBundle()
        // A different mnemonic than the descriptor carries.
        var mismatched = bundle
        mismatched.mnemonic = "legal winner thank year wave sausage worth useful legal winner thank yellow"
        #expect(throws: WalletError.descriptorMismatch) {
            _ = try Wallet.importing(mismatched, keyStore: InMemoryKeyStore())
        }
        // A claimed scriptPubKey that isn't what the descriptor derives.
        var bogus = bundle
        bogus.utxos[0].scriptPubKey = "5120ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        #expect(throws: WalletError.self) { _ = try Wallet.importing(bogus, keyStore: InMemoryKeyStore()) }
        // Neither descriptor nor mnemonic.
        var empty = bundle
        empty.descriptor = nil
        empty.mnemonic = nil
        #expect(throws: WalletError.invalidBundle("need a descriptor or a mnemonic")) {
            _ = try Wallet.importing(empty, keyStore: InMemoryKeyStore())
        }
        // Unknown network / future version.
        var badNetwork = bundle
        badNetwork.network = " PlutoNet "
        #expect(throws: WalletError.self) { _ = try Wallet.importing(badNetwork, keyStore: InMemoryKeyStore()) }
        var future = bundle
        future.version = 99
        #expect(throws: WalletError.invalidBundle("unsupported version 99")) {
            _ = try Wallet.importing(future, keyStore: InMemoryKeyStore())
        }

        var invalidAmount = bundle
        invalidAmount.utxos[0].amount = Int64.max
        #expect(throws: WalletError.invalidBundle("invalid UTXO amount \(Int64.max)")) {
            _ = try Wallet.importing(invalidAmount, keyStore: InMemoryKeyStore())
        }
        var duplicate = bundle
        duplicate.utxos.append(duplicate.utxos[0])
        #expect(throws: WalletError.invalidBundle("duplicate UTXO outpoint")) {
            _ = try Wallet.importing(duplicate, keyStore: InMemoryKeyStore())
        }
        var invalidHistory = bundle
        invalidHistory.transactions[0].received = -1
        #expect(throws: WalletError.invalidBundle("transaction history has invalid amounts")) {
            _ = try Wallet.importing(invalidHistory, keyStore: InMemoryKeyStore())
        }
    }

    @Test("verify report: confirmed, spent-since-bundle (mismatch), discovered")
    func report() async throws {
        let bundle = try await makeBundle()
        let keyStore = InMemoryKeyStore()
        let wallet = try Wallet.importing(bundle, keyStore: keyStore)
        let claimed = try bundle.claimedUTXOs()

        var effects: [MatchEffect] = []
        // Block 501: claimed UTXO 0 gets spent by someone else; a new payment
        // the bundle didn't know about arrives at receive index 2.
        let spendTx = Transaction(version: 2, inputs: [
            Transaction.Input(previousOutput: claimed[0].outpoint, scriptSig: Data(), sequence: 0xFFFF_FFFF),
        ], outputs: [Transaction.Output(value: 99_000,
                                        scriptPubKey: Data([0x51, 0x20] + repeatElement(0x77, count: 32)))],
        locktime: 0)
        let newScript = try await wallet.scriptPubKey(chain: .receive, index: 2)
        let incomingTx = Transaction(version: 2, inputs: [coinbaseInput()], outputs: [
            Transaction.Output(value: 25_000, scriptPubKey: newScript),
        ], locktime: 0)
        let match = fakeMatch(height: 501, transactions: [spendTx, incomingTx])
        effects.append(try await wallet.apply(match: match))

        let report = try await ImportReport.make(bundle: bundle, effects: effects,
                                                 finalUTXOs: wallet.utxos,
                                                 scannedFromHeight: 501, scannedToHeight: 501)
        #expect(!report.matchesBundle)
        #expect(report.spentSinceBundle.count == 1)
        #expect(report.spentSinceBundle[0].txid == claimed[0].txid)
        #expect(report.spentSinceBundle[0].spentBy == spendTx.txid)
        #expect(report.spentSinceBundle[0].height == 501)
        #expect(report.confirmedUTXOs.map(\.txid) == [claimed[1].txid])
        #expect(report.discoveredUTXOs.count == 1)
        #expect(report.discoveredUTXOs[0].amount == 25_000)
        // The wallet state itself also reflects the spend and the discovery.
        #expect(await wallet.balance == 75_000)
        #expect(await wallet.nextReceiveIndex == 3)
    }

    @Test("a bundle exported at the tip verifies clean (empty scan)")
    func cleanReport() async throws {
        let bundle = try await makeBundle()
        let wallet = try Wallet.importing(bundle, keyStore: InMemoryKeyStore())
        let report = try await ImportReport.make(bundle: bundle, effects: [],
                                                 finalUTXOs: wallet.utxos,
                                                 scannedFromHeight: 501, scannedToHeight: nil)
        #expect(report.matchesBundle)
        #expect(report.confirmedUTXOs.count == 2)
        #expect(report.discoveredUTXOs.isEmpty)
    }

    /// Funds a wallet at receive index 0 so export has a live UTXO + history.
    private func fundedWallet(keyStore: KeyStore = InMemoryKeyStore()) async throws -> Wallet {
        try await TestSupport.fundedWallet(keyStore: keyStore, coins: [(.receive, 0, 200_000, 100)],
                                           mature: false).wallet
    }

    @Test("export → import round trip carries balance, history and scan frontier")
    func exportRoundTrip() async throws {
        let original = try await fundedWallet()
        let bundle = try await original.exportBundle()
        #expect(bundle.version == 2)
        #expect(bundle.mnemonic == nil)
        #expect(bundle.descriptor != nil)
        #expect(bundle.lastKnownHeight == 99) // nextScanHeight 100 − 1
        #expect(bundle.utxos.count == 1)
        #expect(bundle.transactions.count == 1)

        // Display-hex hop: the file's txid is reversed relative to internal order.
        let originalTxid = try #require(await original.utxos.first).txid
        #expect(bundle.utxos[0].txid == originalTxid.displayHex)
        #expect(bundle.utxos[0].txid != originalTxid.hex)

        let json = try bundle.serialized()
        #expect(!json.contains("\"mnemonic\""))
        let parsed = try JSONDecoder().decode(ImportBundle.self, from: Data(json.utf8))
        #expect(parsed == bundle)

        let restored = try Wallet.importing(parsed, keyStore: InMemoryKeyStore())
        #expect(await restored.id == original.id)
        #expect(await restored.balance == 200_000)
        #expect(await restored.utxos.count == 1)
        #expect(await restored.utxos[0].txid == originalTxid)
        #expect(await restored.history.count == 1)
        #expect(await restored.history[0].received == 200_000)
        #expect(await restored.nextScanHeight == 100)
        #expect(await restored.creationHeight == 99)
        #expect(bundle.nextReceiveIndex == 1)
        #expect(await restored.nextReceiveIndex == 1)
        // Watch-only import must not invent a seed.
        let emptyStore = InMemoryKeyStore()
        _ = try Wallet.importing(parsed, keyStore: emptyStore)
        #expect(throws: KeyStoreError.notFound(walletID: "73c5da0a")) {
            _ = try emptyStore.load(walletID: "73c5da0a")
        }
    }

    /// A confirmed send's destination survives a backup.
    ///
    /// The breakdown is the only record of where a confirmed payment went:
    /// the `PendingSend` holding the same facts is retired by the block that
    /// includes the transaction, and forward-only scanning cannot reconstruct
    /// it — a restored wallet rescans from `lastKnownHeight`, which is past
    /// the block in question. A bundle that dropped it therefore lost every
    /// past payment's recipient for good, silently, on the one path a user
    /// takes to keep their history.
    ///
    /// The schema carries it as an optional field and the version stays 2, so
    /// the two directions below are the compatibility argument: a bundle
    /// written now round-trips the breakdown, and one written before the
    /// field imports with it not known rather than empty.
    @Test("a recorded output breakdown crosses an export and comes back")
    func recordedOutputsCrossAnExport() async throws {
        let wallet = try await TestSupport.fundedWallet(
            coins: [(.receive, 0, 150_000, 100)]).wallet
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        let signed = prepared.built.transaction
        // Confirm it: an export refuses a wallet with a send in flight, and
        // the breakdown is the thing that outlives the pending record anyway.
        try await wallet.apply(match: fakeMatch(height: 150, transactions: [signed]))
        try await wallet.recordScanHeight(151)
        let recorded = try #require(await wallet.history.first { $0.txid == signed.txid }?.outputs)
        #expect(!recorded.external.isEmpty, "the wallet knows where this send paid")

        let bundle = try await wallet.exportBundle()
        #expect(bundle.version == 2, "an added optional field is not a new format")
        let json = try bundle.serialized()
        #expect(json.contains("\"outputs\""))

        let restored = try Wallet.importing(
            try ImportBundle.decode(json: json), keyStore: InMemoryKeyStore())
        let entry = try #require(await restored.history.first { $0.txid == signed.txid })
        #expect(entry.outputs == recorded, "where it paid, byte for byte")
        // Everything the schema already carried still made the trip.
        #expect(entry.spent == 150_000)
        #expect(entry.height == 150)

        // The same bundle in its older shape — the key removed, everything
        // else untouched — still imports, with the breakdown not known rather
        // than an empty one claiming the send paid nobody.
        let older = try Self.bundleJSON(json) { transaction in
            var without = transaction
            without.removeValue(forKey: "outputs")
            return without
        }
        let fromOlder = try Wallet.importing(try ImportBundle.decode(json: older),
                                             keyStore: InMemoryKeyStore())
        let olderEntry = try #require(await fromOlder.history.first { $0.txid == signed.txid })
        #expect(olderEntry.outputs == nil)
        #expect(olderEntry.spent == 150_000)
    }

    /// A bundle is the one input a user is invited to paste from anywhere, so
    /// a breakdown arriving in one is held to what the state file is held to
    /// on load: it must be able to describe a transaction. Without this an
    /// import is a way to seed state `Wallet.open` would have refused.
    ///
    /// The cases are the wallet file's, in bundle form: a vout claimed as
    /// both ours and a stranger's, external vouts that repeat, and external
    /// vouts out of order.
    @Test("a bundle whose output breakdown contradicts itself is refused",
          arguments: [["external": [0], "change": [0]],
                      ["external": [1, 1], "change": [0]],
                      ["external": [2, 1], "change": [0]]])
    func inconsistentBundleOutputsAreRefused(shape: [String: [Int]]) async throws {
        let wallet = try await TestSupport.fundedWallet(
            coins: [(.receive, 0, 150_000, 100)]).wallet
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        try await wallet.apply(match: fakeMatch(height: 150,
                                                transactions: [prepared.built.transaction]))
        try await wallet.recordScanHeight(151)
        let json = try await wallet.exportBundle().serialized()
        // The bundle as exported is the control: it imports.
        #expect(throws: Never.self) {
            _ = try Wallet.importing(try ImportBundle.decode(json: json),
                                     keyStore: InMemoryKeyStore())
        }

        let hostile = try Self.bundleJSON(json) { transaction in
            // Only the send carries a breakdown; the funding coinbase is an
            // observed transaction and has none to edit.
            guard let outputs = transaction["outputs"] as? [String: Any],
                  let template = (outputs["external"] as? [[String: Any]])?.first
            else { return transaction }
            var edited = transaction
            edited["outputs"] = [
                "external": (shape["external"] ?? []).map { vout -> [String: Any] in
                    var entry = template
                    entry["vout"] = NSNumber(value: vout)
                    return entry
                },
                "change": (shape["change"] ?? []).map { NSNumber(value: $0) },
            ]
            return edited
        }
        #expect(throws: WalletError.self) {
            _ = try Wallet.importing(try ImportBundle.decode(json: hostile),
                                     keyStore: InMemoryKeyStore())
        }
    }

    /// Applies `transform` to every entry of a bundle's `transactions` array
    /// and gives the JSON back. Editing the serialized form rather than the
    /// struct is the point: it is what a bundle from another writer, or from
    /// an attacker, actually looks like.
    private static func bundleJSON(_ json: String,
                                   _ transform: ([String: Any]) -> [String: Any]) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        var bundle = try #require(object as? [String: Any])
        bundle["transactions"] = try #require(bundle["transactions"] as? [[String: Any]])
            .map(transform)
        return String(decoding: try JSONSerialization.data(withJSONObject: bundle), as: UTF8.self)
    }

    @Test("export with the mnemonic is opt-in and yields a spendable wallet")
    func exportWithMnemonic() async throws {
        let original = try await fundedWallet()
        let watchOnly = try await original.exportBundle(includeMnemonic: false)
        #expect(watchOnly.mnemonic == nil)

        let hot = try await original.exportBundle(includeMnemonic: true)
        #expect(hot.mnemonic == testMnemonic)
        let json = try hot.serialized()
        #expect(json.contains(testMnemonic))

        let keyStore = InMemoryKeyStore()
        let restored = try Wallet.importing(hot, keyStore: keyStore)
        #expect(await restored.id == "73c5da0a")
        #expect(try keyStore.load(walletID: "73c5da0a") == .mnemonic(testMnemonic))
        #expect(try await restored.address(chain: .receive, index: 0)
                    == (try await original.address(chain: .receive, index: 0)))
    }

    @Test("export with the mnemonic refuses an xprv-only wallet")
    func exportXprvRefusesSeed() async throws {
        let keyStore = InMemoryKeyStore()
        let wallet = try await fundedWallet(keyStore: keyStore)
        let id = await wallet.id
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        try keyStore.delete(walletID: id)
        try keyStore.store(.masterKey(master.serialized(network: .testnet)), for: id)
        do {
            _ = try await wallet.exportBundle(includeMnemonic: true)
            Issue.record("expected WalletError.mnemonicUnavailable")
        } catch let error as WalletError {
            #expect(error == .mnemonicUnavailable)
        }
        // Watch-only export still works — the descriptor is public material.
        let watchOnly = try await wallet.exportBundle()
        #expect(watchOnly.mnemonic == nil)
        #expect(watchOnly.descriptor != nil)
    }

    /// The live app path (`AppModel.syncOnce`) calls `apply(match:)` and
    /// drives FilterSync itself — it never goes through `Wallet.scan`.
    /// Without `recordScanHeight`, export would still emit the
    /// creation/import height.
    @Test("app-style apply + recordScanHeight exports the live frontier")
    func exportAfterAppStyleFilterProgress() async throws {
        let storage = tempFileURL("wallet.json")
        defer { try? FileManager.default.removeItem(at: storage.deletingLastPathComponent()) }
        let keyStore = InMemoryKeyStore()
        // App path: apply(match:) + independent FilterSync progress, never
        // Wallet.scan. Persist must land on disk so a reopen sees it.
        let wallet = try makeTestWallet(storageURL: storage, keyStore: keyStore)
        try await fund(wallet, amount: 200_000, height: 100)

        #expect(await wallet.nextScanHeight == 100)
        let stale = try await wallet.exportBundle()
        #expect(stale.lastKnownHeight == 99)

        // FilterSync finished a pass whose next height is 250.
        try await wallet.recordScanHeight(250)
        #expect(await wallet.nextScanHeight == 250)
        let live = try await wallet.exportBundle()
        #expect(live.lastKnownHeight == 249)
        #expect(live.utxos.count == 1)

        let reopened = try Wallet.open(storageURL: storage, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == 250)
        #expect(try await reopened.exportBundle().lastKnownHeight == 249)
    }

    @Test("export carries a known fee; older JSON without the key still decodes")
    func exportPreservesKnownFee() async throws {
        let wallet = try await fundedWallet()
        let utxo = try #require(await wallet.utxos.first)
        var spend = Transaction(version: 2, inputs: [
            Transaction.Input(previousOutput: utxo.outpoint, scriptSig: Data(), sequence: 0xFFFF_FFFD),
        ], outputs: [
            Transaction.Output(value: 199_000,
                               scriptPubKey: Data([0x51, 0x20] + repeatElement(0x55, count: 32))),
        ], locktime: 0)
        spend.inputs[0].witness = [Data(repeating: 0, count: 64)]
        try await wallet.apply(match: fakeMatch(height: 101, transactions: [spend]))
        #expect(await wallet.history[1].fee == 1_000)

        let bundle = try await wallet.exportBundle()
        #expect(bundle.transactions.count == 2)
        #expect(bundle.transactions[0].fee == nil) // incoming funding: fee unknown
        #expect(bundle.transactions[1].fee == 1_000)
        let json = try bundle.serialized()
        #expect(json.contains("\"fee\""))
        // Incoming history must not encode `"fee": null`.
        let parsed = try JSONDecoder().decode(ImportBundle.self, from: Data(json.utf8))
        #expect(parsed.transactions[0].fee == nil)
        #expect(parsed.transactions[1].fee == 1_000)

        let restored = try Wallet.importing(parsed, keyStore: InMemoryKeyStore())
        #expect(await restored.history[0].fee == nil)
        #expect(await restored.history[1].fee == 1_000)

        // Pre-fee v1 files still decode.
        let legacy = """
        {"version":1,"network":"signet","lastKnownHeight":0,"utxos":[],\
        "transactions":[{"txid":"\(Data(repeating: 0x50, count: 32).displayHex)",\
        "height":1,"received":100,"spent":0}]}
        """
        let old = try JSONDecoder().decode(ImportBundle.self, from: Data(legacy.utf8))
        #expect(old.transactions[0].fee == nil)
    }

    @Test("export with mnemonic maps a missing keystore entry to mnemonicUnavailable")
    func exportMissingKeystoreIsMnemonicUnavailable() async throws {
        let keyStore = InMemoryKeyStore()
        let wallet = try await fundedWallet(keyStore: keyStore)
        try keyStore.delete(walletID: await wallet.id)
        do {
            _ = try await wallet.exportBundle(includeMnemonic: true)
            Issue.record("expected WalletError.mnemonicUnavailable")
        } catch let error as WalletError {
            #expect(error == .mnemonicUnavailable)
        } catch {
            Issue.record("leaked \(error) instead of WalletError.mnemonicUnavailable")
        }
        // Watch-only export still works — the descriptor is public material.
        let watchOnly = try await wallet.exportBundle()
        #expect(watchOnly.mnemonic == nil)
    }

    @Test("preview JSON redacts the mnemonic without touching the real file")
    func redactedPreviewHidesMnemonic() async throws {
        let original = try await fundedWallet()
        let hot = try await original.exportBundle(includeMnemonic: true)
        let json = try hot.serialized()
        #expect(json.contains(testMnemonic))
        let preview = ImportBundle.redactedPreview(json)
        #expect(!preview.contains(testMnemonic))
        #expect(preview.contains("\"mnemonic\""))
        #expect(preview.contains("<redacted>"))
        // Watch-only JSON is unchanged (no mnemonic key to redact).
        let watch = try await original.exportBundle().serialized()
        #expect(ImportBundle.redactedPreview(watch) == watch)
    }

    @Test("export refuses a pending send — parent inputs would vanish from a restore")
    func exportRefusesPendingSend() async throws {
        let wallet = try await fundedWallet()
        try await matureCoinbase(wallet, height: 100)
        let matureBundle = try await wallet.exportBundle()
        #expect(matureBundle.utxos.first?.isCoinbase == true)
        let restored = try Wallet.importing(matureBundle, keyStore: InMemoryKeyStore())
        #expect(await restored.utxos.first?.isCoinbase == true)
        let destination = TestScripts.p2trDestination
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 50_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        try await wallet.commit(prepared)
        let built = prepared.built
        #expect(await wallet.utxos.contains(where: { $0.height == 0 }))
        do {
            _ = try await wallet.exportBundle()
            Issue.record("expected WalletError.exportWhilePending")
        } catch let error as WalletError {
            #expect(error == .exportWhilePending)
        }
        try await wallet.apply(match: fakeMatch(height: 101, transactions: [built.transaction]))
        let bundle = try await wallet.exportBundle()
        #expect(bundle.utxos.allSatisfy { $0.height > 0 })
        #expect(bundle.nextChangeIndex == 1)
    }

    @Test("export carries derivation indices so a spent-out restore does not reuse addresses")
    func exportPreservesDerivationIndices() async throws {
        let original = try makeTestWallet()
        _ = try await original.freshReceiveAddress()
        _ = try await original.freshReceiveAddress()
        #expect(await original.nextReceiveIndex == 2)
        #expect(await original.utxos.isEmpty)

        let bundle = try await original.exportBundle()
        #expect(bundle.nextReceiveIndex == 2)
        #expect(bundle.nextChangeIndex == 0)
        #expect(bundle.utxos.isEmpty)

        let restored = try Wallet.importing(bundle, keyStore: InMemoryKeyStore())
        #expect(await restored.nextReceiveIndex == 2)
        #expect(try await restored.address(chain: .receive, index: 2)
                    == (try await original.address(chain: .receive, index: 2)))

        // Older files without the keys still decode; the importer then uses
        // the UTXO-derived floor (0 here — nothing claimed).
        var legacy = bundle
        legacy.nextReceiveIndex = nil
        legacy.nextChangeIndex = nil
        let old = try Wallet.importing(legacy, keyStore: InMemoryKeyStore())
        #expect(await old.nextReceiveIndex == 0)
    }

    // MARK: - Import bundle bounds
    //
    // Bounds and decoding semantics for imported bundles (invariants S7, S10).
    //
    // A bundle is the one input a user is actively invited to paste from
    // anywhere. Two of the properties it relies on are Foundation's, not
    // Winnow's: `JSONDecoder` refuses deeply nested JSON, and it resolves a
    // duplicate key to its *first* occurrence. Both are undocumented defaults.
    // They are pinned here so that a Foundation change cannot quietly alter
    // what a bundle means — a duplicate `network` key silently flipping from
    // `signet` to `mainnet` would change which chain a restored wallet
    // believes it is on.
    //
    // The explicit size bounds are what Foundation does not provide at all.

    static func bundle(utxos: String = "", transactions: String = "", extra: String = "") -> String {
        """
        {"version":2,"network":"signet","lastKnownHeight":1\(extra),\
        "utxos":[\(utxos)],"transactions":[\(transactions)]}
        """
    }

    static let coin = #"{"txid":"aa","vout":0,"amount":1,"scriptPubKey":"51","chain":0,"index":0,"height":1}"#

    // MARK: Decoding semantics that belong to Foundation

    /// A duplicate key resolves to its first occurrence. This is the safer of
    /// the two possible answers — it matches what a person reading the file
    /// top to bottom sees — but it is worth a test precisely because nothing
    /// in the format guarantees it.
    @Test("a duplicate key resolves to its first occurrence")
    func duplicateKeyTakesTheFirstValue() throws {
        let json = #"""
        {"version":2,"network":"signet","network":"mainnet","lastKnownHeight":1,"utxos":[],"transactions":[]}
        """#
        let bundle = try ImportBundle.decode(json: json)
        #expect(bundle.network == "signet",
                "a later duplicate key must not silently change the bundle's network")
    }

    /// Deeply nested JSON is refused rather than exhausting the stack. The
    /// descriptor parser needed its own bound for exactly this reason
    /// (`SEC-010`); this records that the JSON path already has one.
    @Test("deeply nested JSON is refused", arguments: [512, 20_000])
    func deeplyNestedJSONRefused(_ depth: Int) {
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let json = Self.bundle(extra: ",\"junk\":\(nested)")
        #expect(throws: (any Error).self) {
            _ = try ImportBundle.decode(json: json)
        }
    }

    // MARK: Bounds Winnow has to impose itself

    /// Foundation will decode a bundle of any size. Every declared coin is
    /// then materialised and scanned, so the count is bounded before the
    /// allocation rather than after it.
    @Test("a bundle above the entry limit is refused")
    func tooManyEntriesRefused() throws {
        let coins = Array(repeating: Self.coin, count: ImportBundle.maximumEntries + 1)
            .joined(separator: ",")
        #expect(throws: WalletError.self) {
            _ = try ImportBundle.decode(json: Self.bundle(utxos: coins))
        }
    }

    @Test("a bundle above the byte limit is refused")
    func tooLargeRefused() throws {
        let filler = String(repeating: "a", count: ImportBundle.maximumSerializedBytes)
        let json = Self.bundle(extra: ",\"descriptor\":\"\(filler)\"")
        #expect(json.utf8.count > ImportBundle.maximumSerializedBytes)
        #expect(throws: WalletError.self) {
            _ = try ImportBundle.decode(json: json)
        }
    }

    /// Positive controls: ordinary bundles, and one right at the entry limit,
    /// still decode. Without these the refusals above could be explained by
    /// the decoder rejecting everything.
    @Test("an ordinary bundle decodes")
    func ordinaryBundleDecodes() throws {
        let bundle = try ImportBundle.decode(json: Self.bundle(utxos: Self.coin))
        #expect(bundle.network == "signet")
        #expect(bundle.utxos.count == 1)
    }

    @Test("a bundle exactly at the entry limit is accepted")
    func atTheLimitAccepted() throws {
        let coins = Array(repeating: Self.coin, count: ImportBundle.maximumEntries)
            .joined(separator: ",")
        let bundle = try ImportBundle.decode(json: Self.bundle(utxos: coins))
        #expect(bundle.utxos.count == ImportBundle.maximumEntries)
    }

    /// A known transaction whose breakdown names `external` payments at the
    /// first vouts and `change` at the vouts after them, ascending, so the
    /// only thing a test built from it can be refused for is how many there
    /// are.
    static func transaction(external: Int = 0, change: Int) -> String {
        let payments = (0 ..< external)
            .map { #"{"vout":\#($0),"amount":1,"scriptPubKey":"51"}"# }
            .joined(separator: ",")
        let vouts = (external ..< external + change).map(String.init).joined(separator: ",")
        return #"{"txid":"aa","height":1,"received":0,"spent":0,"outputs":{"external":[\#(payments)],"change":[\#(vouts)]}}"#
    }

    /// A breakdown is a list nested inside a list, and the entry limit
    /// counted only the outer one. A change vout is a few bytes, so one
    /// transaction could name more outputs than the whole bundle may hold
    /// coins in a file a fraction of the byte limit, and every one of them
    /// was materialised and validated.
    @Test("a transaction naming more outputs than the entry limit is refused")
    func tooManyOutputsInOneTransactionRefused() throws {
        let json = Self.bundle(transactions: Self.transaction(change: ImportBundle.maximumEntries + 1))
        #expect(json.utf8.count < ImportBundle.maximumSerializedBytes,
                "the count, not the byte limit, must be what refuses this")
        #expect(throws: WalletError.self) {
            _ = try ImportBundle.decode(json: json)
        }
    }

    /// `total` breakdown outputs spread over transactions of at most
    /// `perTransaction` each, so a test can put the whole bundle at one
    /// limit while every transaction stays inside the other.
    static func transactions(totalOutputs total: Int, perTransaction: Int) -> String {
        var parts: [String] = []
        var remaining = total
        while remaining > 0 {
            let count = min(remaining, perTransaction)
            parts.append(transaction(external: 1, change: count - 1))
            remaining -= count
        }
        return parts.joined(separator: ",")
    }

    /// The per-transaction ceiling stands on its own: a bundle far inside
    /// the entry limit is still refused when one breakdown names more
    /// outputs than a standard transaction can hold. The one entry over is
    /// an external payment, so both lists are being counted.
    @Test("a breakdown past what one standard transaction can hold is refused")
    func outputsPastThePerTransactionCeilingRefused() throws {
        let transaction = Self.transaction(external: 1,
                                           change: ImportBundle.maximumOutputsPerTransaction)
        #expect(ImportBundle.maximumOutputsPerTransaction + 1 < ImportBundle.maximumEntries,
                "the entry limit must not be what refuses this")
        #expect(throws: WalletError.self) {
            _ = try ImportBundle.decode(json: Self.bundle(transactions: transaction))
        }
    }

    /// Positive control for both bounds: every transaction exactly at the
    /// per-transaction ceiling and the bundle exactly at the entry limit
    /// decodes with every entry intact.
    @Test("breakdowns exactly at both limits are accepted")
    func outputsAtTheLimitsAccepted() throws {
        let json = Self.bundle(transactions: Self.transactions(
            totalOutputs: ImportBundle.maximumEntries,
            perTransaction: ImportBundle.maximumOutputsPerTransaction))
        let bundle = try ImportBundle.decode(json: json)
        let perTransaction = bundle.transactions.map {
            ($0.outputs?.external.count ?? 0) + ($0.outputs?.change.count ?? 0)
        }
        #expect(perTransaction.reduce(0, +) == ImportBundle.maximumEntries)
        #expect(perTransaction.max() == ImportBundle.maximumOutputsPerTransaction)
    }

    /// The bundle-wide limit stands on its own too: transactions each well
    /// inside the per-transaction ceiling, whose breakdowns together name
    /// one entry more than the bundle may hold.
    @Test("breakdowns that together exceed the entry limit are refused")
    func outputsSpreadPastTheEntryLimitRefused() throws {
        let json = Self.bundle(transactions: Self.transactions(
            totalOutputs: ImportBundle.maximumEntries + 1,
            perTransaction: ImportBundle.maximumOutputsPerTransaction / 2))
        #expect(json.utf8.count < ImportBundle.maximumSerializedBytes)
        #expect(throws: WalletError.self) {
            _ = try ImportBundle.decode(json: json)
        }
    }

    /// Malformed input still fails as an error rather than anything worse.
    @Test("truncated JSON is refused")
    func truncatedJSONRefused() {
        #expect(throws: (any Error).self) {
            _ = try ImportBundle.decode(json: #"{"version":2,"network":"sig"#)
        }
    }
}
