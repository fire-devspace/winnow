@testable import WinnowApp
import XCTest

final class SyncPhaseDisplayTests: XCTestCase {
    func testFilterScanTextUsesLivePhaseInsteadOfStaleWalletSnapshot() {
        let scanned: UInt32 = 162_000
        let tip: UInt32 = 963_221
        let phase = AppModel.SyncPhase.filters(scanned: scanned, tip: tip)

        XCTAssertEqual(
            phase.filterScanText(fallbackScanned: 0, fallbackTip: 0),
            "block \(scanned.formatted()) of \(tip.formatted())"
        )
    }

    func testFilterScanTextClampsNextHeightAtTip() {
        let nextHeight: UInt32 = 963_222
        let tip: UInt32 = 963_221
        let phase = AppModel.SyncPhase.filters(scanned: nextHeight, tip: tip)

        XCTAssertEqual(
            phase.filterScanText(fallbackScanned: 0, fallbackTip: 0),
            "block \(tip.formatted()) of \(tip.formatted())"
        )
    }

    func testFilterScanTextFallsBackOutsideFilterPhase() {
        let phase = AppModel.SyncPhase.headers(synced: 100, tipEstimate: 200)

        XCTAssertEqual(
            phase.filterScanText(fallbackScanned: 40, fallbackTip: 100),
            "block 40 of 100"
        )
    }

    func testFilterScanTextClampsCompletedSnapshotAfterSync() {
        let tip: UInt32 = 963_221
        let phase = AppModel.SyncPhase.synced

        XCTAssertEqual(
            phase.filterScanText(fallbackScanned: tip + 1, fallbackTip: tip),
            "block \(tip.formatted()) of \(tip.formatted())"
        )
    }
}
