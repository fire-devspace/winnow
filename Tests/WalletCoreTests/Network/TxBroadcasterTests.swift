import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// TxBroadcaster's relay behaviour, against loopback nodes: inv announcement
/// and the getdata answer, the BIP133 fee filter, the backoff table, and the
/// deprioritisation of a peer that never asks.
///
/// Combined from `TxBroadcaster` (minus its store-persistence tests, which are
/// now in `TxBroadcasterStoreTests.swift`), `TxBroadcaster backoff schedule`
/// and `Fee filter announcements`. Only the last of the three carried a suite
/// trait, `.timeLimit(.minutes(2))`; it is the stricter of the three and so it
/// is the trait this suite keeps.
@Suite("TxBroadcaster", .timeLimit(.minutes(2)))
struct TxBroadcasterTests {

    // MARK: - TxBroadcaster
    //
    // Announcement, the getdata answer, confirmation and cancellation, the
    // fee floor. The store-persistence cases these used to sit beside are in
    // `TxBroadcasterStoreTests`.

    @Test("announces witness-tx inv to all peers and answers getdata")
    func announceAndServe() async throws {
        let params = NetworkParams.signet
        let nodeA = LoopbackNode(params: params)
        let nodeB = LoopbackNode(params: params)
        let nodeC = LoopbackNode(params: params)
        for node in [nodeA, nodeB, nodeC] { try await node.start() }
        defer { for node in [nodeA, nodeB, nodeC] { Task { await node.stop() } } }

        var endpoints: [PeerEndpoint] = []
        for node in [nodeA, nodeB, nodeC] { endpoints.append(await node.endpoint) }

        let store = tempFileURL("pending-txs.json")
        let pool = PeerPool(params: params, peerCount: 3, manualPeers: endpoints)
        await pool.start()
        #expect(await pool.connectedPeers().count == 3)

        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                        rebroadcastBaseInterval: .seconds(3_600))
        let events = await broadcaster.events()
        let tx = makeFakeSegwitTx()
        let rawTx = tx.serialized(includeWitness: true)
        let txid = try await broadcaster.broadcast(rawTx)
        #expect(txid == tx.txid)

        // Every node must receive inv(MSG_WITNESS_TX, txid), then get the tx
        // when it asks via getdata.
        for node in [nodeA, nodeB, nodeC] {
            let invMessage = await node.nextMessage(command: "inv")
            guard case let .inv(payload) = invMessage else {
                Issue.record("no inv received")
                continue
            }
            #expect(payload.vectors == [InventoryVector(type: .witnessTx, hash: txid)])
            try await node.send(.getdata(InventoryPayload(payload.vectors)))
            let txMessage = await node.nextMessage(command: "tx")
            guard case let .tx(served) = txMessage else {
                Issue.record("no tx received")
                continue
            }
            #expect(served == tx)
        }

        // Events: announced to 3 peers, then requested by each.
        let seen = EventCollector<TxBroadcaster.Event>()
        let consumer = Task {
            for await event in events { seen.add(event) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let events = seen.events
            if events.contains(where: {
                if case .announced(_, peerCount: 3) = $0 { return true }
                return false
            }), events.filter({ if case .requested = $0 { return true }; return false }).count == 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        consumer.cancel()
        #expect(seen.events.contains {
            if case .announced(_, peerCount: 3) = $0 { return true }
            return false
        })
        #expect(seen.events.filter {
            if case .requested = $0 { return true }
            return false
        }.count == 3)

        // Pending tx survives a restart (JSON persistence).
        let reloaded = try TxBroadcaster(pool: pool, storageURL: store)
        #expect(await reloaded.pendingTxids == [txid])

        try await broadcaster.markConfirmed(txid, atHeight: 1)
        #expect(await broadcaster.pendingTxids.isEmpty)

        await pool.stop()
        try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
    }

    @Test("broadcasting malformed raw tx data throws")
    func malformedTx() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let broadcaster = try TxBroadcaster(pool: pool)
        await #expect(throws: (any Error).self) {
            try await broadcaster.broadcast(Data([0x01, 0x02, 0x03]))
        }
    }

    @Test("serves a delayed getdata and tracks per-peer state")
    func delayedGetdata() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params, autoRequestDelay: .milliseconds(100))
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()

        let broadcaster = try TxBroadcaster(pool: pool, rebroadcastBaseInterval: .seconds(3_600))
        let seen = EventCollector<TxBroadcaster.Event>()
        let events = await broadcaster.events()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }

        let tx = makeFakeSegwitTx()
        let txid = try await broadcaster.broadcast(tx.serialized(includeWitness: true))
        let endpoint = await node.endpoint

        // The node requests after its delay and is then served the tx.
        let served = await pollUntil {
            seen.events.contains { $0 == .served(txid: txid, peer: endpoint) }
        }
        #expect(served)
        #expect(seen.events.contains { $0 == .requested(txid: txid, peer: endpoint) })
        #expect(await broadcaster.relayStatus(txid)[endpoint.description] == .served)

        guard case let .tx(servedTx) = await node.nextMessage(command: "tx") else {
            Issue.record("node never received the tx")
            return
        }
        #expect(servedTx == tx)

        await pool.stop()
    }

    @Test("deprioritizes a peer that never answers invs with getdata")
    func deprioritizesSilentPeer() async throws {
        let params = NetworkParams.signet
        let nodeA = LoopbackNode(params: params, autoRequestDelay: .milliseconds(20))
        let nodeB = LoopbackNode(params: params, autoRequestDelay: .milliseconds(20))
        let silent = LoopbackNode(params: params) // never requests
        for node in [nodeA, nodeB, silent] { try await node.start() }
        defer { for node in [nodeA, nodeB, silent] { Task { await node.stop() } } }

        var endpoints: [PeerEndpoint] = []
        for node in [nodeA, nodeB, silent] { endpoints.append(await node.endpoint) }
        let silentEndpoint = await silent.endpoint

        let pool = PeerPool(params: params, peerCount: 3, manualPeers: endpoints)
        await pool.start()
        #expect(await pool.connectedPeers().count == 3)

        let broadcaster = try TxBroadcaster(pool: pool,
                                        rebroadcastBaseInterval: .milliseconds(150),
                                        maxRebroadcastInterval: .milliseconds(600),
                                        maxAnnouncementsPerPeer: 2,
                                        announcementTimeout: .milliseconds(100))
        let seen = EventCollector<TxBroadcaster.Event>()
        let events = await broadcaster.events()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }

        let txid = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))

        // After exactly 2 unanswered announcements the silent peer is skipped.
        let dropped = await pollUntil {
            seen.events.contains { $0 == .deprioritized(txid: txid, peer: silentEndpoint) }
        }
        #expect(dropped)
        #expect(await broadcaster.relayStatus(txid)[silentEndpoint.description] == .deprioritized)

        // It saw exactly the initial inv plus one retry, and nothing after.
        #expect(await silent.nextMessage(command: "inv") != nil)
        #expect(await silent.nextMessage(command: "inv") != nil)
        #expect(await silent.nextMessage(command: "inv", timeout: .milliseconds(800)) == nil)

        // The responsive peers keep being served on every announcement.
        #expect(seen.events.contains { $0 == .served(txid: txid, peer: endpoints[0]) })
        #expect(seen.events.contains { $0 == .served(txid: txid, peer: endpoints[1]) })

        await pool.stop()
    }

    @Test("rebroadcast backs off exponentially, capped, with injected intervals")
    func exponentialBackoff() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params, autoRequestDelay: .milliseconds(20))
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()

        // 100ms base, doubling, capped at 250ms → gaps 100, 200, 250, 250.
        let broadcaster = try TxBroadcaster(pool: pool,
                                        rebroadcastBaseInterval: .milliseconds(100),
                                        maxRebroadcastInterval: .milliseconds(250),
                                        announcementTimeout: .seconds(30))
        let txid = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))

        var schedule: [Date] = []
        if let first = await broadcaster.nextAttemptDate(txid) { schedule.append(first) }
        for attempt in 1 ... 3 {
            // `>=`, not `==`. The counter advances every 100-250ms for as long
            // as the broadcaster runs, so equality asks the poll to observe it
            // inside one interval. A contended runner that misses that window
            // can never satisfy the check again -- the counter is already past
            // it -- so the test burned the full hang-guard three times and
            // failed with the schedule assertions below still passing (#144).
            let reached = await pollUntil {
                await broadcaster.attemptCount(txid) ?? 0 >= attempt
            }
            #expect(reached)
            if let date = await broadcaster.nextAttemptDate(txid) { schedule.append(date) }
        }
        #expect(schedule.count == 4)
        guard schedule.count == 4 else { return }
        let gaps = zip(schedule, schedule.dropFirst()).map { $1.timeIntervalSince($0) }
        // What this test can honestly prove is that attempts fire and that the
        // schedule only ever moves forward. It cannot prove the *size* of a
        // step, nor that any single sample caught its own step: the schedule is
        // sampled by polling, so a loaded runner can advance the counter twice
        // between two samples (leaving a zero gap) or read an already-advanced
        // entry (inflating one). Asserting per-step movement is therefore an
        // assertion about scheduling luck, which is what made this a flaky
        // release gate (#138, #144).
        //
        // So: never backwards, forward overall, and the attempts really fired.
        // The doubling-then-cap shape is checked exhaustively and without a
        // clock in "TxBroadcaster backoff schedule".
        #expect(gaps.allSatisfy { $0 >= 0 }, "the schedule must never move backwards")
        #expect(schedule.last! > schedule.first!, "three attempts must push the schedule forward")
        #expect(await broadcaster.attemptCount(txid) ?? 0 >= 3, "three attempts must have fired")

        await pool.stop()
    }

    @Test("stops rebroadcasting on confirmation and on explicit cancel")
    func stopOnConfirmationAndCancel() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()

        let broadcaster = try TxBroadcaster(pool: pool,
                                        rebroadcastBaseInterval: .milliseconds(150),
                                        maxRebroadcastInterval: .milliseconds(600),
                                        announcementTimeout: .seconds(30))
        let seen = EventCollector<TxBroadcaster.Event>()
        let events = await broadcaster.events()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }

        // Confirmed tx: no further invs.
        let txid1 = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))
        #expect(await node.nextMessage(command: "inv") != nil)
        try await broadcaster.markConfirmed(txid1, atHeight: 1)
        // The pending entry is gone, so no further attempt can be scheduled.
        // That is the claim, and it is deterministic.
        #expect(await broadcaster.pendingTxids.isEmpty)
        // The wire check is about what happens *after* that. Rebroadcasts
        // already sent when the confirmation landed are not counter-examples,
        // and the old drain-then-stay-quiet shape could not tell them apart
        // from real ones: a straggler landing inside the 700ms quiet window
        // failed the test on a loaded runner (#164, twice on main). The
        // barrier consumes everything already in flight, so the quiet window
        // now only ever sees newly scheduled attempts — which the empty
        // pending set above proves cannot exist.
        await drainQueuedInvs(from: node)
        try await stragglersFlushed(node)
        #expect(await node.nextMessage(command: "inv", timeout: .milliseconds(700)) == nil)
        #expect(seen.events.contains { $0 == .confirmed(txid: txid1) })

        // Cancelled tx: no further invs either.
        let txid2 = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))
        #expect(await node.nextMessage(command: "inv") != nil)
        try await broadcaster.cancel(txid2)
        #expect(await broadcaster.pendingTxids.isEmpty)
        // Same shape as the confirmation branch, for the same reason.
        await drainQueuedInvs(from: node)
        try await stragglersFlushed(node)
        #expect(await node.nextMessage(command: "inv", timeout: .milliseconds(700)) == nil)
        #expect(seen.events.contains { $0 == .cancelled(txid: txid2) })

        await pool.stop()
    }

    @Test("emits feeFloorExceeded when every peer's feefilter exceeds the tx feerate")
    func feeFloorExceeded() async throws {
        let params = NetworkParams.signet
        let nodeA = LoopbackNode(params: params, autoRequestDelay: .milliseconds(20))
        let nodeB = LoopbackNode(params: params, autoRequestDelay: .milliseconds(20))
        for node in [nodeA, nodeB] { try await node.start() }
        defer { for node in [nodeA, nodeB] { Task { await node.stop() } } }

        var endpoints: [PeerEndpoint] = []
        for node in [nodeA, nodeB] { endpoints.append(await node.endpoint) }
        let pool = PeerPool(params: params, peerCount: 2, manualPeers: endpoints)
        await pool.start()

        let broadcaster = try TxBroadcaster(pool: pool,
                                        rebroadcastBaseInterval: .milliseconds(150),
                                        maxRebroadcastInterval: .milliseconds(600),
                                        announcementTimeout: .seconds(30))
        let seen = EventCollector<TxBroadcaster.Event>()
        let events = await broadcaster.events()
        let consumer = Task { for await event in events { seen.add(event) } }
        defer { consumer.cancel() }

        // 1 sat/vB = 1000 sat/kvB.
        let txid = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true),
                                                   feeRateSatPerVByte: 1)
        // Drain the initial announcement so later inv checks only match
        // rebroadcasts.
        #expect(await nodeA.nextMessage(command: "inv") != nil)

        // One peer raises its floor to 5 sat/vB, but the other still relays.
        try await nodeA.send(.feefilter(5_000))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!seen.events.contains { if case .feeFloorExceeded = $0 { return true }; return false })

        // Now the second peer raises too: the minimum (5 sat/vB) exceeds the
        // tx's 1 sat/vB — no remaining peer will relay it.
        try await nodeB.send(.feefilter(9_000))
        let emitted = await pollUntil {
            seen.events.contains { $0 == .feeFloorExceeded(txid: txid, floor: 5_000) }
        }
        #expect(emitted)

        // Nothing is announced to a peer that has said it will drop the
        // bytes (BIP133): retries keep running, but node A hears none of them
        // while its floor refuses the transaction. A rebroadcast that fired
        // before node A's floor reached the broadcaster was legitimate and can
        // still sit in A's inbox on a slow runner; drain it, so the window
        // below only sees announcements made after the floor took effect.
        while await nodeA.nextMessage(command: "inv", timeout: .milliseconds(50)) != nil {}
        #expect(await nodeA.nextMessage(command: "inv", timeout: .milliseconds(600)) == nil)

        // Floor dropping back below the feerate rearms the event, and the
        // next attempt announces to node A again…
        try await nodeA.send(.feefilter(500))
        #expect(await nodeA.nextMessage(command: "inv", timeout: .seconds(10)) != nil)
        // …so a later rise emits it again.
        try await nodeA.send(.feefilter(2_000))
        let reemitted = await pollUntil {
            seen.events.filter { if case .feeFloorExceeded = $0 { return true }; return false }.count == 2
        }
        #expect(reemitted)
        #expect(seen.events.contains { $0 == .feeFloorExceeded(txid: txid, floor: 2_000) })

        await pool.stop()
    }

    // MARK: - TxBroadcaster backoff schedule
    //
    // The rebroadcast backoff policy, checked without a clock.
    //
    // The integration test above proves attempts fire and the schedule
    // advances; it deliberately does not measure step sizes, because it
    // samples the schedule by polling and a late poll inflates the
    // measurement. The step sizes live here instead, where they are a pure
    // function of the attempt count and the configured intervals (#138).

    /// Every (base, cap, attempt) the schedule is pinned at, with the interval
    /// it must produce. The cap is inclusive — the guard is `<`, so the moment
    /// doubling would *reach* the cap the cap is taken — and no attempt past
    /// that point, however large, ever schedules beyond it.
    static let steps: [(base: Duration, cap: Duration, attempt: Int, expected: Duration)] = [
        // Doubles from the base on every attempt until the cap, then holds:
        // 200 doubled is 400, past the cap, so the cap is taken instead.
        (.milliseconds(100), .milliseconds(250), 0, .milliseconds(100)),
        (.milliseconds(100), .milliseconds(250), 1, .milliseconds(200)),
        (.milliseconds(100), .milliseconds(250), 2, .milliseconds(250)),
        (.milliseconds(100), .milliseconds(250), 3, .milliseconds(250)),
        (.milliseconds(100), .milliseconds(250), 50, .milliseconds(250)),
        // Doubling 100ms lands exactly on the 200ms cap: the cap wins, and the
        // boundary case does not produce a longer interval than the cap.
        (.milliseconds(100), .milliseconds(200), 1, .milliseconds(200)),
        // An uncapped schedule is exactly base × 2^attempt.
        (.seconds(1), .seconds(3_600), 0, .seconds(1)),
        (.seconds(1), .seconds(3_600), 1, .seconds(2)),
        (.seconds(1), .seconds(3_600), 2, .seconds(4)),
        (.seconds(1), .seconds(3_600), 3, .seconds(8)),
        (.seconds(1), .seconds(3_600), 4, .seconds(16)),
        (.seconds(1), .seconds(3_600), 5, .seconds(32)),
        (.seconds(1), .seconds(3_600), 6, .seconds(64)),
        (.seconds(1), .seconds(3_600), 7, .seconds(128)),
        (.seconds(1), .seconds(3_600), 8, .seconds(256)),
        (.seconds(1), .seconds(3_600), 9, .seconds(512)),
        (.seconds(1), .seconds(3_600), 10, .seconds(1_024)),
        // The shipped defaults double six times before capping at an hour:
        // 1,920 doubled is 3,840 — past the hour cap, so the cap is taken.
        (.seconds(60), .seconds(3_600), 0, .seconds(60)),
        (.seconds(60), .seconds(3_600), 1, .seconds(120)),
        (.seconds(60), .seconds(3_600), 2, .seconds(240)),
        (.seconds(60), .seconds(3_600), 3, .seconds(480)),
        (.seconds(60), .seconds(3_600), 4, .seconds(960)),
        (.seconds(60), .seconds(3_600), 5, .seconds(1_920)),
        (.seconds(60), .seconds(3_600), 6, .seconds(3_600)),
        // ...and no later attempt schedules beyond the cap, out to the
        // counter's saturation point (`retryCounterSaturates` below).
        (.seconds(60), .seconds(3_600), 7, .seconds(3_600)),
        (.seconds(60), .seconds(3_600), 32, .seconds(3_600)),
        (.seconds(60), .seconds(3_600), 63, .seconds(3_600)),
        (.seconds(60), .seconds(3_600), 64, .seconds(3_600)),
        // A cap below the base is a degenerate configuration, but it must not
        // return an interval longer than the cap the caller asked for.
        (.seconds(60), .seconds(10), 0, .seconds(10)),
    ]

    @Test("the interval is base × 2^attempt, capped inclusively and held there",
          arguments: Self.steps)
    func stepIsPinned(_ row: (base: Duration, cap: Duration, attempt: Int, expected: Duration)) {
        let interval = TxBroadcaster.backoffInterval(attempt: row.attempt, base: row.base, cap: row.cap)
        #expect(interval == row.expected,
                "attempt \(row.attempt) from \(row.base) capped at \(row.cap)")
        #expect(interval <= row.cap, "attempt \(row.attempt) exceeded the cap")
    }

    /// The retry counter saturates instead of growing without bound, and the
    /// reason is not tidiness: `load` refuses any record whose attempt is
    /// outside `0...maximumAttempt`, and it refuses by throwing for the whole
    /// file. So an unclamped counter does not cost one transaction -- it makes
    /// the entire pending store unloadable, and every transaction waiting in it
    /// is forgotten at the next launch.
    ///
    /// That state is reachable in practice. At the shipped defaults the
    /// interval caps at an hour, so a transaction still unconfirmed after
    /// roughly two and a half days has fired 64 attempts. Driven here with a
    /// 1ms interval and no peers, so it is arithmetic rather than a wait.
    @Test("the retry counter saturates, leaving the store loadable")
    func retryCounterSaturates() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let store = tempFileURL("pending-saturate.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: store,
                                            rebroadcastBaseInterval: .milliseconds(1),
                                            maxRebroadcastInterval: .milliseconds(1))
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true))

        // Run past the ceiling, then let it keep firing: the point is that it
        // stops climbing, not merely that it arrives.
        var saturated = false
        let deadline = ContinuousClock.now + .seconds(60) // hang-guard, not a deadline
        while ContinuousClock.now < deadline {
            if await broadcaster.attemptCount(txid) ?? 0 >= 63 { saturated = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(saturated)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await broadcaster.attemptCount(txid) == 63,
                "the counter must hold at the ceiling rather than climb past it")
        await broadcaster.shutdown()

        // The consequence that actually matters: the store still loads, so the
        // transaction is still being rebroadcast after a restart.
        let reloaded = try TxBroadcaster(pool: pool, storageURL: store,
                                         rebroadcastBaseInterval: .milliseconds(1),
                                         maxRebroadcastInterval: .milliseconds(1))
        #expect(await reloaded.pendingTxids == [txid],
                "a saturated counter must not make the pending store unloadable")
        await reloaded.shutdown()
    }

    /// The signed bytes stay reachable while a transaction is pending.
    ///
    /// Winnow relays over its own peers with no fallback submission path, so
    /// when relay is not working the transaction itself is the only thing that
    /// can leave the device. Handing the user a txid for something no one has
    /// seen is not much use; handing them the bytes is an escape hatch.
    @Test("a pending transaction's raw bytes can be read back")
    func rawTransactionIsRecoverable() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let broadcaster = try TxBroadcaster(pool: pool,
                                            rebroadcastBaseInterval: .seconds(60))
        let raw = makeFakeSegwitTx().serialized(includeWitness: true)
        let txid = try await broadcaster.broadcast(raw)

        #expect(await broadcaster.rawTransaction(txid) == raw,
                "the bytes handed back must be the bytes that were signed")

        // Unknown txids are simply absent rather than an error.
        #expect(await broadcaster.rawTransaction(Data(repeating: 0xFF, count: 32)) == nil)

        // Once it confirms it is on the chain, and the txid is the handle.
        try await broadcaster.markConfirmed(txid, atHeight: 1)
        #expect(await broadcaster.rawTransaction(txid) == nil)
        await broadcaster.shutdown()
    }

    // MARK: - Fee filter announcements
    //
    // BIP133: a peer whose fee filter is above a transaction's rate has said
    // it will drop the bytes unread. Announcing to it is noise, and the
    // deprioritization it would earn hides the real reason.

    @Test("a peer whose fee filter refuses the transaction is not announced to until the filter drops")
    func feeFilterSkipsPeer() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        _ = await node.nextMessage(command: "verack", timeout: .seconds(10))

        // 100 sat/vB: nothing this test sends clears it.
        try await node.send(.feefilter(100_000))
        let peer = try #require(await pool.connectedPeers().first)
        for _ in 0 ..< 100 where await peer.feeFilter != 100_000 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await peer.feeFilter == 100_000)

        let broadcaster = try TxBroadcaster(pool: pool,
                                            rebroadcastBaseInterval: .milliseconds(300),
                                            maxRebroadcastInterval: .milliseconds(600),
                                            announcementTimeout: .seconds(30))
        defer { Task { await broadcaster.shutdown() } }
        let txid = try await broadcaster.broadcast(
            makeFakeSegwitTx().serialized(includeWitness: true), feeRateSatPerVByte: 2)
        #expect(await node.nextMessage(command: "inv", timeout: .seconds(1)) == nil,
                "the peer said it would drop it; no announcement")
        #expect(await broadcaster.relayStatus(txid).isEmpty,
                "skipped, not marked: no relay state was recorded against the peer")

        // The filter drops to 1 sat/vB; the next scheduled attempt announces.
        try await node.send(.feefilter(1_000))
        #expect(await node.nextMessage(command: "inv", timeout: .seconds(10)) != nil,
                "a filter that later allows the transaction lets the peer back in")
    }
}

/// Consumes every inv already queued on `node`, so a following assertion is
/// about what arrives *next* rather than what was already in flight.
///
/// Bounded so a broadcaster that never stops fails the test instead of hanging
/// it — the drain is meant to remove a finite backlog, not to wait out an
/// unbounded stream.
private func drainQueuedInvs(from node: LoopbackNode, limit: Int = 20) async {
    for _ in 0 ..< limit {
        if await node.nextMessage(command: "inv", timeout: .milliseconds(250)) == nil { return }
    }
}

/// A TCP ordering barrier (#164). The connection is one ordered stream, so by
/// the time the client's `pong` arrives, every message it dispatched before
/// answering has arrived too. Draining after the barrier therefore consumes
/// any rebroadcast that was already in flight when the confirmation landed —
/// the stragglers that used to land inside the quiet window and fail the
/// negative assertion on a loaded runner. An inv after barrier-plus-drain can
/// only be a *newly scheduled* attempt, which is exactly what the assertion
/// is supposed to catch.
private func stragglersFlushed(_ node: LoopbackNode) async throws {
    try await node.send(.ping(0xB412_B412_B412_B412))
    let pong = await node.nextMessage(command: "pong", timeout: .seconds(10))
    #expect(pong != nil, "the client stopped answering pings — the barrier proves nothing")
    await drainQueuedInvs(from: node)
}
