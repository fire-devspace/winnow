@testable import WinnowApp
import WalletCore
import XCTest

@MainActor
final class PersistedWalletOpeningTests: XCTestCase {
    func testMissingWalletIsOnboardingCase() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-wallet-\(UUID().uuidString).json")

        switch AppModel.openPersistedWallet(at: url, keyStore: InMemoryKeyStore()) {
        case .missing:
            break
        case .opened, .damaged:
            XCTFail("a missing file was not classified as missing")
        }
    }

    func testDamagedWalletNeverLooksMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("damaged-wallet-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not wallet json".utf8).write(to: url, options: .atomic)

        switch AppModel.openPersistedWallet(at: url, keyStore: InMemoryKeyStore()) {
        case let .damaged(message):
            XCTAssertTrue(message.contains("could not safely read"))
            XCTAssertTrue(message.contains("left untouched"))
        case .missing, .opened:
            XCTFail("damaged state was treated as an absent or usable wallet")
        }
    }
}
