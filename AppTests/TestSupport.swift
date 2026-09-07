@testable import WinnowApp
import BitcoinP2P
import Foundation
import TestSupport

/// Fixtures shared across AppTests. What conforms to an app protocol has to
/// live here rather than in the package's TestSupport library.

/// A device authenticator that always approves, so a model can be driven
/// without a passcode prompt.
final class SilentAuthenticator: DeviceAuthenticating {
    func authenticate(reason: String) async throws {}
}

/// A fresh model on the silent authenticator.
@MainActor
func makeModel() -> AppModel {
    AppModel(deviceAuthenticator: SilentAuthenticator())
}

/// A signed transaction the broadcaster will accept, so a real relay entry can
/// be written and then damaged, confirmed or rolled back. Shaped like a signed
/// transaction rather than being one: nothing on this side checks a witness.
let signedTransactionBytes: Data = makeFakeSegwitTx().serialized(includeWitness: true)
