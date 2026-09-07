@testable import WinnowApp
import BitcoinCore
import BitcoinP2P
import TestSupport
import WalletCore
import XCTest

final class VaultStoreSecurityTests: XCTestCase {
    func testMissingVaultFileIsAnEmptyStore() async {
        let url = tempFileURL("vault-store.json")
        let store = VaultStore()

        let result = await store.configure(storageURL: url, network: .signet)
        let records = await store.all
        XCTAssertEqual(result, .missing)
        XCTAssertEqual(records, [])
    }

    func testMalformedVaultFileFailsClosedAndIsNotRewritten() async throws {
        let url = tempFileURL("vault-store.json")
        let original = Data("not vault json".utf8)
        try original.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VaultStore()

        guard case let .damaged(message) = await store.configure(storageURL: url, network: .signet)
        else { return XCTFail("malformed storage was accepted") }
        XCTAssertTrue(message.contains("left untouched"))
        let records = await store.all
        XCTAssertEqual(records, [])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOneInvalidRecordRejectsTheWholeSnapshot() async throws {
        let fixture = try makeFixture()
        var invalid = fixture.record
        invalid.id = "00000000"
        let url = try write([fixture.record, invalid])
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VaultStore()

        guard case .damaged = await store.configure(storageURL: url, network: .signet)
        else { return XCTFail("partially invalid storage was accepted") }
        let records = await store.all
        XCTAssertEqual(records, [])
    }

    func testDuplicateVaultAndOutpointSnapshotsFailClosed() async throws {
        let fixture = try makeFixture()
        var funded = fixture.record
        funded.nextReceiveIndex = 1
        funded.allUtxos = [try funding(vault: fixture.vault, amount: 10_000)]

        var duplicateOutpoint = funded
        duplicateOutpoint.allUtxos.append(funded.allUtxos[0])
        for records in [[fixture.record, fixture.record], [duplicateOutpoint]] {
            let url = try write(records)
            defer { try? FileManager.default.removeItem(at: url) }
            let store = VaultStore()
            guard case .damaged = await store.configure(storageURL: url, network: .signet)
            else { return XCTFail("duplicate persisted identity was accepted") }
        }
    }

    func testWrongScriptAndImpossibleAmountsFailClosed() async throws {
        let fixture = try makeFixture()
        var wrongScript = try funding(vault: fixture.vault, amount: 10_000)
        wrongScript.scriptPubKey = Data([0x51])
        var overMaximum = try funding(vault: fixture.vault, amount: BitcoinAmount.maximum)
        overMaximum.vout = 1
        let oneMore = try funding(vault: fixture.vault, amount: 1)

        let candidates: [[WalletUTXO]] = [
            [wrongScript],
            [try funding(vault: fixture.vault, amount: -1)],
            [overMaximum, oneMore],
        ]
        for utxos in candidates {
            var record = fixture.record
            record.nextReceiveIndex = 1
            record.allUtxos = utxos
            let url = try write([record])
            defer { try? FileManager.default.removeItem(at: url) }
            let store = VaultStore()
            guard case .damaged = await store.configure(storageURL: url, network: .signet)
            else { return XCTFail("invalid vault output metadata was accepted") }
        }
    }

    func testMaximumIndexCannotOverflowLookaheadOrMutation() async throws {
        let fixture = try makeFixture()
        var record = fixture.record
        record.nextReceiveIndex = VaultStore.maximumNextIndex + 1
        let damagedURL = try write([record])
        defer { try? FileManager.default.removeItem(at: damagedURL) }
        let damagedStore = VaultStore()
        guard case .damaged = await damagedStore.configure(storageURL: damagedURL, network: .signet)
        else { return XCTFail("oversized persisted index was accepted") }

        record.nextReceiveIndex = VaultStore.maximumNextIndex
        let validURL = try write([record])
        defer { try? FileManager.default.removeItem(at: validURL) }
        let store = VaultStore()
        let result = await store.configure(storageURL: validURL, network: .signet)
        XCTAssertEqual(result, .loaded)
        do {
            try await store.advanceReceiveIndex(id: record.id)
            XCTFail("maximum index was incremented")
        } catch {
            let currentIndex = await store.all.first?.nextReceiveIndex
            XCTAssertEqual(currentIndex, VaultStore.maximumNextIndex)
        }
    }

    func testFailedPersistenceRollsBackTheLiveSnapshotAndLeavesFileUntouched() async throws {
        enum ExpectedFailure: Error { case write }
        let fixture = try makeFixture()
        let url = try write([fixture.record])
        let original = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VaultStore(writeData: { _, _ in throw ExpectedFailure.write })
        let result = await store.configure(storageURL: url, network: .signet)
        XCTAssertEqual(result, .loaded)

        do {
            try await store.advanceReceiveIndex(id: fixture.record.id)
            XCTFail("failed persistence was reported as successful")
        } catch ExpectedFailure.write {
            let records = await store.all
            XCTAssertEqual(records, [fixture.record])
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    /// The maturity gate reads `isCoinbase` off the record's coins, so the
    /// store must set it at admission — a block's first transaction is its
    /// coinbase by consensus — and must keep it across a reload: the flag is
    /// state, not something a later scan can rediscover.
    func testCoinbaseOutputsAreFlaggedAndTheFlagSurvivesPersistence() async throws {
        let fixture = try makeFixture()
        let url = try write([fixture.record])
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VaultStore()
        _ = await store.configure(storageURL: url, network: .signet)

        let vaultScript = try fixture.vault.scriptPubKey(index: 0)
        let coinbase = Transaction(
            version: 2,
            inputs: [Transaction.Input(
                previousOutput: Transaction.Outpoint(txid: Data(repeating: 0, count: 32),
                                                     vout: 0xFFFF_FFFF),
                scriptSig: Data([0x01, 0x02]), sequence: 0xFFFF_FFFF)],
            outputs: [Transaction.Output(value: 5_000_000_000, scriptPubKey: vaultScript)],
            locktime: 0)
        let ordinary = Transaction(
            version: 2,
            inputs: [Transaction.Input(
                previousOutput: Transaction.Outpoint(txid: Data(repeating: 9, count: 32), vout: 0),
                scriptSig: Data(), sequence: 0xFFFF_FFFF)],
            outputs: [Transaction.Output(value: 25_000, scriptPubKey: vaultScript)],
            locktime: 0)
        let header = BlockHeader(version: 1, previousHash: Data(repeating: 0, count: 32),
                                 merkleRoot: coinbase.txid, time: 1_600_000_000,
                                 bits: 0x207F_FFFF, nonce: 0)
        let block = Block(header: header, transactions: [coinbase, ordinary])
        try await store.apply(match: BlockMatch(height: 200, blockHash: header.hash,
                                                block: block),
                              network: .signet)

        let applied = await store.all.first?.utxos ?? []
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied.first { $0.txid == coinbase.txid }?.isCoinbase, true)
        XCTAssertEqual(applied.first { $0.txid == ordinary.txid }?.isCoinbase, false)

        let reloaded = VaultStore()
        _ = await reloaded.configure(storageURL: url, network: .signet)
        let persisted = await reloaded.all.first?.utxos ?? []
        XCTAssertEqual(persisted.first { $0.txid == coinbase.txid }?.isCoinbase, true)
        XCTAssertEqual(persisted.first { $0.txid == ordinary.txid }?.isCoinbase, false)
    }

    private func makeFixture() throws -> (record: VaultRecord, vault: Vault) {
        let masters = try [UInt8(0x31), 0x42].map { try TestVaults.master(entropyByte: $0) }
        let keys = try masters.map { try TestVaults.keyExpression(master: $0) }
        let descriptor = try Vault.multiADescriptor(threshold: 2, cosigners: keys)
        let serialized = descriptor.serialized()
        let id = String(serialized.split(separator: "#").last!)
        return (VaultRecord(id: id, name: "Test vault", descriptor: serialized,
                            createdAtHeight: 100),
                try Vault(descriptor: descriptor, network: .signet))
    }

    private func funding(vault: Vault, amount: Int64) throws -> WalletUTXO {
        WalletUTXO(txid: Data(repeating: UInt8(truncatingIfNeeded: amount), count: 32),
                   vout: 0, amount: amount,
                   scriptPubKey: try vault.scriptPubKey(index: 0),
                   chain: .receive, index: 0, height: 100)
    }

    private func write(_ records: [VaultRecord]) throws -> URL {
        let url = tempFileURL("vault-store.json")
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        return url
    }
}
