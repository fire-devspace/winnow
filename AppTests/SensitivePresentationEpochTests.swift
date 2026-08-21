@testable import WinnowApp
import XCTest

final class SensitivePresentationEpochTests: XCTestCase {
    func testCurrentTokenIsAcceptedOnlyWhileSceneIsActive() {
        var epoch = SensitivePresentationEpoch()
        let token = epoch.begin()

        XCTAssertTrue(epoch.accepts(token, whilePresentationIsAllowed: true))
        XCTAssertFalse(epoch.accepts(token, whilePresentationIsAllowed: false))
    }

    func testInvalidationRejectsAnAsyncResultFromTheOldPresentation() {
        var epoch = SensitivePresentationEpoch()
        let stale = epoch.begin()

        epoch.invalidate()

        XCTAssertFalse(epoch.accepts(stale, whilePresentationIsAllowed: true))
    }

    func testStartingAnotherOperationRejectsThePreviousResult() {
        var epoch = SensitivePresentationEpoch()
        let stale = epoch.begin()
        let current = epoch.begin()

        XCTAssertFalse(epoch.accepts(stale, whilePresentationIsAllowed: true))
        XCTAssertTrue(epoch.accepts(current, whilePresentationIsAllowed: true))
    }
}
