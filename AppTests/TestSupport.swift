@testable import WinnowApp
import WalletCore
import Foundation
import TestSupport
import XCTest

/// Fixtures shared across AppTests. What conforms to an app protocol has to
/// live here rather than in the package's TestSupport library.

/// A device authenticator that always approves, so a model can be driven
/// without a passcode prompt.
final class SilentAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async throws {}
}

extension XCTestCase {
    /// Each test owns its preferences; teardown removes the whole suite.
    func makeDefaults() -> UserDefaults {
        let name = "winnow-tests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
        }
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    func makeModel(network: BitcoinNetwork? = nil, defaults: UserDefaults? = nil,
                   deviceAuthenticator: any DeviceAuthenticating = SilentAuthenticator()) -> AppModel {
        let defaults = defaults ?? makeDefaults()
        if let network { defaults.set(network.rawValue, forKey: AppModel.DefaultsKey.network) }
        return AppModel(deviceAuthenticator: deviceAuthenticator, e2e: nil, defaults: defaults)
    }
}

/// A signed transaction the broadcaster will accept, so a real relay entry can
/// be written and then damaged, confirmed or rolled back. Shaped like a signed
/// transaction rather than being one: nothing on this side checks a witness.
let signedTransactionBytes: Data = makeFakeSegwitTx().serialized(includeWitness: true)
