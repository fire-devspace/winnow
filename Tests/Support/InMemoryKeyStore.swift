import Foundation
import WalletCore

/// In-memory KeyStore for tests and ephemeral use. Not persisted; secrets are
/// lost when the instance is dropped.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private var secrets: [String: WalletSecret] = [:]
    private let lock = NSLock()

    public init() {}

    public func store(_ secret: WalletSecret, for walletID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard secrets[walletID] == nil else { throw KeyStoreError.alreadyExists(walletID: walletID) }
        secrets[walletID] = secret
    }

    public func load(walletID: String) throws -> WalletSecret {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = secrets[walletID] else { throw KeyStoreError.notFound(walletID: walletID) }
        return secret
    }

    public func delete(walletID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: walletID)
    }
}
