@testable import WinnowApp
import BitcoinP2P
import WalletCore
import XCTest

final class SendReviewBindingTests: XCTestCase {
    private let baseline = SendReviewInputs(
        destination: "tb1p-old-destination",
        amountText: "10000",
        priority: .medium,
        overrideText: "",
        network: .signet
    )

    func testEveryAuthorizationInputInvalidatesTheReviewIdentity() {
        XCTAssertNotEqual(
            baseline,
            SendReviewInputs(destination: "tb1p-new-destination", amountText: baseline.amountText,
                             priority: baseline.priority, overrideText: baseline.overrideText,
                             network: baseline.network)
        )
        XCTAssertNotEqual(
            baseline,
            SendReviewInputs(destination: baseline.destination, amountText: "20000",
                             priority: baseline.priority, overrideText: baseline.overrideText,
                             network: baseline.network)
        )
        XCTAssertNotEqual(
            baseline,
            SendReviewInputs(destination: baseline.destination, amountText: baseline.amountText,
                             priority: .high, overrideText: baseline.overrideText,
                             network: baseline.network)
        )
        XCTAssertNotEqual(
            baseline,
            SendReviewInputs(destination: baseline.destination, amountText: baseline.amountText,
                             priority: baseline.priority, overrideText: "5.0",
                             network: baseline.network)
        )
        XCTAssertNotEqual(
            baseline,
            SendReviewInputs(destination: baseline.destination, amountText: baseline.amountText,
                             priority: baseline.priority, overrideText: baseline.overrideText,
                             network: .mainnet)
        )
    }

    func testParsingUsesTheCapturedReviewFields() {
        let captured = baseline
        let edited = SendReviewInputs(destination: "tb1p-new-destination", amountText: "20000",
                                      priority: .high, overrideText: "5.0", network: .signet)

        XCTAssertEqual(captured.trimmedDestination, "tb1p-old-destination")
        XCTAssertEqual(captured.amount, 10_000)
        XCTAssertNotEqual(captured, edited)
    }

    func testFeeBumpReviewBindsTransactionAndRequestedRate() {
        let txid = Data(repeating: 0x11, count: 32)
        let baseline = FeeBumpReviewInputs(txid: txid, targetRateText: " 2.5 ")

        XCTAssertEqual(baseline.targetRate, 2.5)
        XCTAssertNotEqual(
            baseline,
            FeeBumpReviewInputs(txid: Data(repeating: 0x22, count: 32), targetRateText: " 2.5 ")
        )
        XCTAssertNotEqual(
            baseline,
            FeeBumpReviewInputs(txid: txid, targetRateText: "3.0")
        )
    }
}
