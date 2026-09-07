import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The TxBroadcaster pending store: what is written, what is refused, what a
/// failed write must not leave behind, and the confirmation tombstones a reorg
/// resurrects.
///
/// Combined from the store-persistence tests of the `TxBroadcaster` suite —
/// the damaged store, the legacy and versioned formats, and the failed-write
/// paths — and from `TxBroadcaster reorg tombstones`. Neither source suite
/// carried a trait, so this one carries none either.
@Suite("TxBroadcaster store")
struct TxBroadcasterStoreTests {

    // MARK: - TxBroadcaster: pending store
    //
    // Persistence is the part of the broadcaster with no peers in it: what
    // reaches the file, which files load, and which are refused as a whole
    // rather than half-read.

    @Test("pending store round-trips backoff state and still loads the legacy format")
    func persistenceRoundTrip() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-txs.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                        rebroadcastBaseInterval: .milliseconds(100))
        let tx = makeFakeSegwitTx()
        let rawTx = tx.serialized(includeWitness: true)
        let txid = try await broadcaster.broadcast(rawTx, feeRateSatPerVByte: 2.5)

        // Let at least one backoff attempt fire so `attempt` advances past 0.
        #expect(await pollUntil { await broadcaster.attemptCount(txid) ?? 0 >= 1 })

        // Then stop the loop before sampling anything. While the broadcaster
        // runs, `attempt` advances every 100ms, so reading the file and the
        // live counter are two different moments and pinning either to a
        // literal 1 is a race, not an invariant (#144).
        await broadcaster.shutdown()

        // The store carries the raw tx, feerate and next-attempt time.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [String: Any]
        let record = (json?["transactions"] as? [String: Any])?[txid.hex] as? [String: Any]
        let persistedAttempt = record?["attempt"] as? Int
        #expect(record?["rawTx"] as? String == rawTx.hex)
        #expect(record?["feeRateSatPerVByte"] as? Double == 2.5)
        #expect(persistedAttempt ?? 0 >= 1, "the fired attempt must reach the store")
        #expect(record?["nextAttemptAt"] as? Double != nil)
        #expect(json?["version"] as? Int == 1)

        // A fresh broadcaster restores tx, feerate and schedule. The claim is
        // that what comes back equals what went to disk -- comparing against
        // the persisted value rather than a literal is what makes this a
        // round-trip assertion instead of a timing one.
        let restored = try TxBroadcaster(pool: pool, storageURL: store,
                                     rebroadcastBaseInterval: .milliseconds(100))
        #expect(await restored.pendingTxids == [txid])
        #expect(await restored.attemptCount(txid) == persistedAttempt)
        #expect(await restored.nextAttemptDate(txid) != nil)

        try await restored.cancel(txid)

        // The pre-backoff format (txid → rawTx) still loads, due immediately.
        let legacyStore = tempFileURL("pending-legacy.json")
        defer { try? FileManager.default.removeItem(at: legacyStore.deletingLastPathComponent()) }
        let legacy = #"{"transactions": {"\#(txid.hex)": "\#(rawTx.hex)"}}"#
        try Data(legacy.utf8).write(to: legacyStore)
        let legacyLoaded = try TxBroadcaster(pool: pool, storageURL: legacyStore)
        #expect(await legacyLoaded.pendingTxids == [txid])
        try await legacyLoaded.cancel(txid)
    }

    @Test("missing, disabled, and loaded persistence are distinguished")
    func persistenceState() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-state.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        let disabled = try TxBroadcaster(pool: pool)
        #expect(disabled.persistenceState == .disabled)
        let missing = try TxBroadcaster(pool: pool, storageURL: store)
        #expect(missing.persistenceState == .missing)

        let tx = makeFakeSegwitTx()
        _ = try await missing.broadcast(tx.serialized(includeWitness: true))
        let loaded = try TxBroadcaster(pool: pool, storageURL: store)
        #expect(loaded.persistenceState == .loaded(transactionCount: 1))
    }

    @Test("damaged persistence is rejected as a whole and never rewritten")
    func damagedPersistenceFailsClosed() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-damaged.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let tx = makeFakeSegwitTx()
        let raw = tx.serialized(includeWitness: true)
        let otherTxid = Data(repeating: 0x42, count: 32).hex
        let bytes = Data(#"{"version":1,"transactions":{"\#(tx.txid.hex)":{"rawTx":"\#(raw.hex)","attempt":0,"nextAttemptAt":1},"\#(otherTxid)":{"rawTx":"00","attempt":0,"nextAttemptAt":1}}}"#.utf8)
        try bytes.write(to: store)

        #expect(throws: TxBroadcasterStorageError.self) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }
        #expect(try Data(contentsOf: store) == bytes)
    }

    @Test("txid mismatch, unsupported versions, and hostile retry metadata are rejected")
    func invalidStoredMetadata() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-hostile.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let tx = makeFakeSegwitTx()
        let raw = tx.serialized(includeWitness: true).hex
        let wrongTxid = Data(repeating: 0x24, count: 32).hex

        try Data(#"{"version":2,"transactions":{}}"#.utf8).write(to: store)
        #expect(throws: TxBroadcasterStorageError.unsupportedVersion(2)) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }

        try Data(#"{"version":1,"transactions":{"\#(wrongTxid)":{"rawTx":"\#(raw)","attempt":0,"nextAttemptAt":1}}}"#.utf8).write(to: store)
        #expect(throws: TxBroadcasterStorageError.self) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }

        try Data(#"{"version":1,"transactions":{"\#(tx.txid.hex)":{"rawTx":"\#(raw)","feeRateSatPerVByte":0,"attempt":0,"nextAttemptAt":1}}}"#.utf8).write(to: store)
        #expect(throws: TxBroadcasterStorageError.self) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }

        try Data(#"{"version":1,"transactions":{"\#(tx.txid.hex)":{"rawTx":"\#(raw)","attempt":64,"nextAttemptAt":1}}}"#.utf8).write(to: store)
        #expect(throws: TxBroadcasterStorageError.self) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }

        try Data(#"{"version":1,"transactions":{"\#(tx.txid.hex)":{"rawTx":"\#(raw)","attempt":0,"nextAttemptAt":999999999999}}}"#.utf8).write(to: store)
        #expect(throws: TxBroadcasterStorageError.self) {
            _ = try TxBroadcaster(pool: pool, storageURL: store)
        }
    }

    @Test("invalid fee rates and failed initial writes never create pending relay state")
    func broadcastPersistenceIsTransactional() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("missing-parent/pending.json")
        try FileManager.default.removeItem(at: store.deletingLastPathComponent())
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store)
        let raw = makeFakeSegwitTx().serialized(includeWitness: true)

        await #expect(throws: TxBroadcasterError.invalidFeeRate) {
            try await broadcaster.broadcast(raw, feeRateSatPerVByte: .nan)
        }
        await #expect(throws: TxBroadcasterStorageError.writeFailed) {
            try await broadcaster.broadcast(raw, feeRateSatPerVByte: 1)
        }
        #expect(await broadcaster.pendingTxids.isEmpty)
    }

    @Test("failed confirmation and cancellation writes retain pending state and emit no success")
    func removalPersistenceIsTransactional() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-removal.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                            rebroadcastBaseInterval: .seconds(3_600))
        let events = await broadcaster.events()
        let seen = EventCollector<TxBroadcaster.Event>()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }
        let txid = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))
        try FileManager.default.removeItem(at: store.deletingLastPathComponent())

        await #expect(throws: TxBroadcasterStorageError.writeFailed) {
            try await broadcaster.markConfirmed(txid, atHeight: 1)
        }
        await #expect(throws: TxBroadcasterStorageError.writeFailed) {
            try await broadcaster.cancel(txid)
        }
        #expect(await broadcaster.pendingTxids == [txid])
        #expect(!seen.events.contains { $0 == .confirmed(txid: txid) })
        #expect(!seen.events.contains { $0 == .cancelled(txid: txid) })
    }

    @Test("failed retry persistence halts automatic announcements and reports the error")
    func retryPersistenceFailureStopsLoop() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-retry.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                            rebroadcastBaseInterval: .milliseconds(100))
        let events = await broadcaster.events()
        let seen = EventCollector<TxBroadcaster.Event>()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }
        let txid = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))
        try FileManager.default.removeItem(at: store.deletingLastPathComponent())

        #expect(await pollUntil {
            seen.events.contains { if case .persistenceFailed = $0 { return true }; return false }
        })
        #expect(await broadcaster.attemptCount(txid) == 0)
        let announcementCount = seen.events.filter {
            if case let .announced(id, _) = $0 { return id == txid }
            return false
        }.count
        try await Task.sleep(for: .milliseconds(350))
        #expect(seen.events.filter {
            if case let .announced(id, _) = $0 { return id == txid }
            return false
        }.count == announcementCount)
    }

    @Test("shutdown clears only the live session and leaves durable relay state for reconnect")
    func shutdownPreservesStore() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-shutdown.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                            rebroadcastBaseInterval: .seconds(3_600))
        let raw = makeFakeSegwitTx().serialized(includeWitness: true)
        let txid = try await broadcaster.broadcast(raw)

        await broadcaster.shutdown()
        #expect(await broadcaster.pendingTxids.isEmpty)
        await #expect(throws: TxBroadcasterError.stopped) {
            try await broadcaster.broadcast(raw)
        }
        await #expect(throws: TxBroadcasterError.stopped) {
            try await broadcaster.cancel(txid)
        }

        let reconnected = try TxBroadcaster(pool: pool, storageURL: store)
        #expect(await reconnected.pendingTxids == [txid])
        try await reconnected.cancel(txid)
    }

    // MARK: - TxBroadcaster reorg tombstones
    //
    // The broadcaster half of #157: a confirmation is a tombstone, not a
    // deletion, so a reorg that disconnects the confirming block can
    // re-announce the transaction instead of finding its raw bytes gone.

    /// A held entry is silent and invisible — pendingTxids means "in flight",
    /// the raw bytes stay withdrawn (the #155 decision), and the backoff loop
    /// has nothing to run.
    @Test("a confirmed entry is held, not pending")
    func confirmedEntryIsHeld() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let broadcaster = try TxBroadcaster(pool: pool)
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))
        try await broadcaster.markConfirmed(txid, atHeight: 500)

        #expect(await broadcaster.pendingTxids.isEmpty, "held is not in flight")
        #expect(await broadcaster.rawTransaction(txid) == nil,
                "confirmed bytes stay withdrawn, exactly as before this change")
    }

    /// The point of holding it: a reorg above the fork resurrects the entry
    /// and the network hears the transaction again.
    @Test("a reorg past the confirmation re-announces the transaction")
    func reorgReannounces() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let broadcaster = try TxBroadcaster(pool: pool,
                                            rebroadcastBaseInterval: .milliseconds(100),
                                            maxRebroadcastInterval: .milliseconds(400),
                                            announcementTimeout: .seconds(30))
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))
        #expect(await node.nextMessage(command: "inv") != nil, "initial announcement")

        try await broadcaster.markConfirmed(txid, atHeight: 500)
        #expect(await broadcaster.pendingTxids.isEmpty)

        try await broadcaster.rollBack(to: 400)
        #expect(await broadcaster.pendingTxids == [txid], "in flight again")
        #expect(await node.nextMessage(command: "inv", timeout: .seconds(10)) != nil,
                "the resurrected transaction must reach the wire again")
    }

    /// A fork below the confirmation changes nothing: the block that confirmed
    /// the transaction is still on the surviving chain.
    @Test("a reorg below the confirmation leaves the entry held")
    func shallowReorgLeavesHeld() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let broadcaster = try TxBroadcaster(pool: pool)
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))
        try await broadcaster.markConfirmed(txid, atHeight: 300)

        try await broadcaster.rollBack(to: 350)
        #expect(await broadcaster.pendingTxids.isEmpty,
                "confirmed at 300, fork at 350: the confirmation stands")
    }

    /// Held entries age out on the wallet's own reorg horizon, so the store
    /// cannot grow one entry per confirmed send forever.
    @Test("held entries are pruned past the 100-block horizon")
    func heldEntriesPrune() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("prune-held.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store)
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))
        try await broadcaster.markConfirmed(txid, atHeight: 500)

        try await broadcaster.pruneConfirmed(scannedTo: 599)
        try await broadcaster.rollBack(to: 400)
        #expect(await broadcaster.pendingTxids == [txid],
                "at 99 deep the entry must survive — the wallet can still reorganise over it")

        try await broadcaster.markConfirmed(txid, atHeight: 500)
        try await broadcaster.pruneConfirmed(scannedTo: 600)
        try await broadcaster.rollBack(to: 400)
        #expect(await broadcaster.pendingTxids.isEmpty,
                "at 100 deep it is gone, the same horizon spent-coin tombstones use")
    }

    /// The tombstone survives a restart, and so does its resurrectability —
    /// a reorg noticed after relaunch still re-announces.
    @Test("a held entry survives a restart and can still be resurrected")
    func heldEntrySurvivesRestart() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("held-restart.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store)
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))
        try await broadcaster.markConfirmed(txid, atHeight: 500)

        let reloaded = try TxBroadcaster(pool: pool, storageURL: store)
        #expect(await reloaded.pendingTxids.isEmpty, "still held after the restart")
        #expect(await reloaded.rawTransaction(txid) == nil, "still withdrawn after the restart")

        try await reloaded.rollBack(to: 400)
        #expect(await reloaded.pendingTxids == [txid],
                "the raw bytes survived the restart precisely so this works")
    }
}
