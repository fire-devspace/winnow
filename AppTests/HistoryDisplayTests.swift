@testable import WinnowApp
import WalletCore
import XCTest

@MainActor
final class HistoryDisplayTests: XCTestCase {
    private func entry(_ id: UInt8, height: UInt32 = 0, replacedBy: UInt8? = nil) -> HistoryEntry {
        HistoryEntry(txid: Data(repeating: id, count: 32), height: height,
                     received: 0, spent: 1,
                     replacedBy: replacedBy.map { Data(repeating: $0, count: 32) })
    }

    func testReplacementStaysBesideItsOriginalBeforeAndAfterConfirmation() {
        let receipts = (1 ... 100).map { entry(UInt8($0), height: UInt32($0)) }
        let original = entry(101, replacedBy: 103)
        let otherPending = entry(102)
        let replacement = entry(103)
        let history = receipts + [original, otherPending, replacement]

        XCTAssertEqual(Array(AppModel.historyForDisplay(history).prefix(3)).map(\.txid),
                       [replacement.txid, original.txid, otherPending.txid],
                       "the replaced payment must not be buried below old receipts")

        var confirmed = history
        confirmed[confirmed.count - 1].height = 110
        confirmed.append(entry(104, height: 111))
        XCTAssertEqual(Array(AppModel.historyForDisplay(confirmed).prefix(5)).map(\.txid),
                       [otherPending.txid, entry(104).txid, replacement.txid, original.txid, entry(100).txid],
                       "the whole replacement group must move below newer confirmed payments")
    }

    func testRepeatedBumpsFollowTheirFinalPaymentRegardlessOfImportOrder() {
        let original = entry(1, replacedBy: 2)
        let middle = entry(2, replacedBy: 3)
        let final = entry(3, height: 110)
        let recent = entry(4, height: 111)
        XCTAssertEqual(AppModel.historyForDisplay([middle, recent, original, final]).map(\.txid),
                       [recent.txid, final.txid, middle.txid, original.txid])
    }

    func testIncompleteOrCyclicReplacementLinksDoNotHideHistory() {
        let history = [entry(1, replacedBy: 2), entry(2, replacedBy: 1),
                       entry(3, replacedBy: 9), entry(4, height: 100)]
        let displayed = AppModel.historyForDisplay(history)
        XCTAssertEqual(Set(displayed.map(\.txid)), Set(history.map(\.txid)))
        XCTAssertEqual(displayed.first?.txid, entry(4).txid)
    }
}
