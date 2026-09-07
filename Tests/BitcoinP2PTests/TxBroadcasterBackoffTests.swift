import Foundation
import Testing
import TestSupport
@testable import BitcoinP2P

/// The rebroadcast backoff policy, checked without a clock.
///
/// The integration test in `TxBroadcasterTests` proves attempts fire and the
/// schedule advances; it deliberately does not measure step sizes, because it
/// samples the schedule by polling and a late poll inflates the measurement.
/// The step sizes live here instead, where they are a pure function of the
/// attempt count and the configured intervals (#138).
@Suite("TxBroadcaster backoff schedule")
struct TxBroadcasterBackoffTests {

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
}
