import Foundation

/// Invalidates results produced by an earlier presentation of sensitive UI.
///
/// Cancellation alone is not a sufficient boundary: LocalAuthentication,
/// Keychain, or another dependency may finish after its caller is cancelled.
/// A result may enter SwiftUI state only while its token is still current and
/// the scene is active.
struct SensitivePresentationEpoch: Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private var current: Token?

    mutating func begin() -> Token {
        let token = Token(id: UUID())
        current = token
        return token
    }

    mutating func invalidate() {
        current = nil
    }

    func accepts(_ token: Token, whilePresentationIsAllowed isAllowed: Bool) -> Bool {
        isAllowed && current == token
    }
}
