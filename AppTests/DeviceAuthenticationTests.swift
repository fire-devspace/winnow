@testable import WinnowApp
import XCTest

@MainActor
final class DeviceAuthenticationTests: XCTestCase {
    private final class RecordingAuthenticator: DeviceAuthenticating {
        enum Failure: Error { case denied }

        var reasons: [String] = []
        var shouldFail = false

        func authenticate(reason: String) async throws {
            reasons.append(reason)
            if shouldFail { throw Failure.denied }
        }
    }

    func testSensitiveActionUsesInjectedDeviceAuthenticator() async throws {
        let authenticator = RecordingAuthenticator()
        let model = AppModel(deviceAuthenticator: authenticator)

        try await model.authenticateSensitiveAction(reason: "Authorize test operation")

        XCTAssertEqual(authenticator.reasons, ["Authorize test operation"])
    }

    func testSensitiveActionFailsClosedWhenAuthenticationFails() async {
        let authenticator = RecordingAuthenticator()
        authenticator.shouldFail = true
        let model = AppModel(deviceAuthenticator: authenticator)

        do {
            try await model.authenticateSensitiveAction(reason: "Authorize test operation")
            XCTFail("authentication failure was ignored")
        } catch RecordingAuthenticator.Failure.denied {
            XCTAssertEqual(authenticator.reasons, ["Authorize test operation"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
