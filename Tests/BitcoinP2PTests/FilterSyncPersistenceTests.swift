import Foundation
import Testing
@testable import BitcoinP2P

@Suite("FilterSync persistence")
struct FilterSyncPersistenceTests {
    @Test("disabled, missing, and valid loaded progress are distinguished")
    func persistenceStates() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-state.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        let disabled = try FilterSync(pool: pool, chain: chain, startHeight: 3)
        #expect(disabled.persistenceState == .disabled)
        #expect(await disabled.nextScanHeight == 3)

        let missing = try FilterSync(pool: pool, chain: chain, startHeight: 3, storageURL: store)
        #expect(missing.persistenceState == .missing)
        #expect(await missing.nextScanHeight == 3)

        try writeProgress(.init(nextScanHeight: 3,
                                filterHeaders: ["2": Data(repeating: 0x11, count: 32).hex]),
                          to: store)
        let loaded = try FilterSync(pool: pool, chain: chain, startHeight: 3, storageURL: store)
        #expect(loaded.persistenceState == .loaded)
        #expect(await loaded.nextScanHeight == 3)
        #expect(await loaded.filterHeader(at: 2) == Data(repeating: 0x11, count: 32))
    }

    @Test("malformed JSON is rejected and its bytes are preserved")
    func malformedJSONPreserved() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-malformed.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let original = Data(#"{"nextScanHeight":"not-a-number","filterHeaders":{}}"#.utf8)
        try original.write(to: store)

        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
        #expect(try Data(contentsOf: store) == original)
    }

    @Test("an unreadable existing path is not treated as missing progress")
    func unreadableProgress() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-is-a-directory")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)

        #expect(throws: FilterSyncStorageError.unreadable) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test("low frontiers, malformed keys and hashes, and future pins fail closed")
    func invalidProgressFields() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-invalid-fields.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        try writeProgress(.init(nextScanHeight: 4), to: store)
        #expect(throws: FilterSyncStorageError.frontierBeforeWallet(stored: 4, wallet: 5)) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 5, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5,
                                filterHeaders: ["04": Data(repeating: 1, count: 32).hex]),
                          to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5, filterHeaders: ["4": "abcd"]), to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5,
                                filterHeaders: ["5": Data(repeating: 2, count: 32).hex]),
                          to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
    }

    @Test("a forged frontier beyond the validated tip is rejected without rewriting or blaming the peer")
    func frontierBeyondTip() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let store = tempFileURL("filter-forged-frontier.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        try writeProgress(.init(nextScanHeight: 100), to: store)
        let original = try Data(contentsOf: store)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: store, requiredCheckpointPeers: 1)

        await #expect(throws: FilterSyncStorageError.frontierBeyondTip(stored: 100, tip: 6)) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        #expect(await sync.nextScanHeight == 100)
        #expect(try Data(contentsOf: store) == original)
        #expect(await pool.connectedPeers().count == 1)
    }

    @Test("a failed batch write leaves the in-memory frontier and pins unchanged")
    func failedBatchWriteIsTransactional() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let store = tempFileURL("filter-write-failure/progress.json")
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: store, requiredCheckpointPeers: 1)
        try FileManager.default.removeItem(at: store.deletingLastPathComponent())

        await #expect(throws: FilterSyncStorageError.writeFailed) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        #expect(await sync.nextScanHeight == 1)
        #expect(await sync.filterHeader(at: 1) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    private func writeProgress(_ progress: FilterSync.Progress, to url: URL) throws {
        try JSONEncoder().encode(progress).write(to: url, options: .atomic)
    }
}
