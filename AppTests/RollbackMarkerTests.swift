@testable import WinnowApp
import BitcoinP2P
import Foundation
import WalletCore
import XCTest

/// The crash marker has to fail closed (#127).
///
/// The rollback spans four stores that persist independently, so a crash
/// part-way through leaves them disagreeing. The marker is what makes that
/// recoverable: because a rollback is a pure function of the fork height it is
/// idempotent, so recovery is a redo rather than a repair.
///
/// That only holds if the target is genuinely recorded before anything moves.
/// Both of these pin a `try?` that had quietly defeated the mechanism it was
/// written to protect — the failure mode being a silent one, where the code
/// reads as if the guarantee holds.
@MainActor
final class RollbackMarkerTests: XCTestCase {
    private final class SilentAuthenticator: DeviceAuthenticating {
        func authenticate(reason: String) async throws {}
    }

    private func makeModel() -> AppModel {
        AppModel(deviceAuthenticator: SilentAuthenticator())
    }

    /// The stores a rollback moves, with a fork to find: a wallet scanned
    /// through block 500, a filter frontier that agrees, and one own send the
    /// broadcaster holds as confirmed at 300. Nothing is persisted and the
    /// pool is never started; the model gets them by the same assignments the
    /// adopt path makes.
    private struct Fixture {
        let wallet: Wallet
        let stack: AppModel.SyncStack
        let txid: Data
    }

    private func makeFixture() async throws -> Fixture {
        let wallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(), storageURL: nil,
                                       entropy: Data(repeating: 0, count: 16), creationHeight: 100)
        try await wallet.recordScanHeight(501)
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: 501, storageURL: nil)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: nil)
        let txid = try await broadcaster.broadcast(signedTransactionBytes)
        try await broadcaster.markConfirmed(txid, atHeight: 300)
        let stack = AppModel.SyncStack(pool: pool, chain: chain, filters: filters, broadcaster: broadcaster)
        return Fixture(wallet: wallet, stack: stack, txid: txid)
    }

    /// Writes the target a crash would have left behind, clearing whatever a
    /// previous run left at that path first.
    private func writeMarker(_ height: String, for model: AppModel) throws -> URL {
        let marker = try XCTUnwrap(model.storageDirectory()).appending(path: AppModel.rollbackMarkerName)
        try? FileManager.default.removeItem(at: marker)
        try Data(height.utf8).write(to: marker, options: .atomic)
        return marker
    }

    /// If the target cannot be written, nothing may change. Proceeding into
    /// the rollbacks unprotected is exactly the state the marker prevents: a
    /// crash then leaves the stores disagreeing with nothing to trigger a redo.
    func testAFailedMarkerWriteStopsTheRollback() async throws {
        let model = makeModel()
        let directory = try XCTUnwrap(model.storageDirectory())
        let marker = directory.appending(path: AppModel.rollbackMarkerName)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: marker.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: marker)
        }

        // A directory where the marker's name should be: the write cannot
        // succeed, and must not be shrugged off.
        try? FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)

        var thrown: (any Error)?
        do {
            try await model.rollBackStores(to: 200)
        } catch {
            thrown = error
        }
        XCTAssertNotNil(thrown, "an unrecordable rollback must not proceed silently")

        try? FileManager.default.removeItem(at: marker)
    }

    /// The happy path, so the test above is not passing because the marker is
    /// broken in general.
    func testTheTargetIsRecordedBeforeTheStoresMove() async throws {
        let model = makeModel()
        let directory = try XCTUnwrap(model.storageDirectory())
        let marker = directory.appending(path: AppModel.rollbackMarkerName)
        defer { try? FileManager.default.removeItem(at: marker) }
        try? FileManager.default.removeItem(at: marker)

        try await model.rollBackStores(to: 4_242)

        let recorded = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(recorded.trimmingCharacters(in: .whitespacesAndNewlines), "4242")
    }

    /// …and it is cleared once the sync that followed has finished, or every
    /// later launch would redo a rollback that already completed.
    func testFinishClearsTheTarget() async throws {
        let model = makeModel()
        let directory = try XCTUnwrap(model.storageDirectory())
        let marker = directory.appending(path: AppModel.rollbackMarkerName)
        defer { try? FileManager.default.removeItem(at: marker) }
        // The simulator keeps its container between runs, so clear whatever a
        // previous test left at this path -- including a directory.
        try? FileManager.default.removeItem(at: marker)

        try await model.rollBackStores(to: 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
        model.finishRollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    /// A marker holding something that is not a height is inert cruft, not a
    /// reason to refuse to launch: there is no height to roll back to, so
    /// there is nothing to redo.
    func testAGarbageMarkerIsInert() async throws {
        let model = makeModel()
        let directory = try XCTUnwrap(model.storageDirectory())
        let marker = directory.appending(path: AppModel.rollbackMarkerName)
        defer { try? FileManager.default.removeItem(at: marker) }
        try Data("not a height".utf8).write(to: marker, options: .atomic)

        try await model.resumeInterruptedRollback()
    }

    /// No marker means no interrupted rollback, which must be silent.
    func testNoMarkerIsSilent() async throws {
        let model = makeModel()
        if let directory = model.storageDirectory() {
            try? FileManager.default.removeItem(
                at: directory.appending(path: AppModel.rollbackMarkerName))
        }
        try await model.resumeInterruptedRollback()
    }

    // MARK: - The redo itself

    /// The redo runs on a booted model, where `wallet` and `stack` are set.
    /// On the fresh model the tests above use, every rewind in it is an
    /// optional-chained no-op, so they prove the marker and nothing else.
    /// This installs the stores and checks that each one moved to the fork.
    func testResumeRewindsWalletFiltersAndBroadcaster() async throws {
        let model = makeModel()
        let marker = try writeMarker("200", for: model)
        defer { try? FileManager.default.removeItem(at: marker) }
        let fixture = try await makeFixture()
        await model.installForTesting(wallet: fixture.wallet, stack: fixture.stack)

        try await model.resumeInterruptedRollback()

        let walletFrontier = await fixture.wallet.nextScanHeight
        XCTAssertEqual(walletFrontier, 201, "the wallet rescans from the block after the fork")
        let filters = try XCTUnwrap(fixture.stack.filters)
        let filterFrontier = await filters.nextScanHeight
        XCTAssertEqual(filterFrontier, 201, "the filter frontier follows the wallet")
        let pending = await fixture.stack.broadcaster.pendingTxids
        XCTAssertEqual(pending, [fixture.txid], "a send whose block fell is in flight again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                       "a completed redo clears the target")
        await fixture.stack.broadcaster.shutdown()
    }

    /// The control. A fork above every frontier leaves nothing scanned in
    /// doubt: no frontier may move forward, and a send whose block survived
    /// stays held rather than being announced again.
    func testResumeAboveEverythingChangesNothing() async throws {
        let model = makeModel()
        let marker = try writeMarker("900", for: model)
        defer { try? FileManager.default.removeItem(at: marker) }
        let fixture = try await makeFixture()
        await model.installForTesting(wallet: fixture.wallet, stack: fixture.stack)

        try await model.resumeInterruptedRollback()

        let walletFrontier = await fixture.wallet.nextScanHeight
        XCTAssertEqual(walletFrontier, 501, "a rollback never moves the wallet forward")
        let filters = try XCTUnwrap(fixture.stack.filters)
        let filterFrontier = await filters.nextScanHeight
        XCTAssertEqual(filterFrontier, 501, "a rollback never moves the filter frontier forward")
        let pending = await fixture.stack.broadcaster.pendingTxids
        XCTAssertTrue(pending.isEmpty, "a send confirmed below the fork stays held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)),
                       "a redo with nothing to do still clears the target")
        await fixture.stack.broadcaster.shutdown()
    }
}
