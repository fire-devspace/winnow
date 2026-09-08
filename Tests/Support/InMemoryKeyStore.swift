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

/// An `InMemoryKeyStore` that counts its reads, so a test can assert how often
/// an operation loaded the master secret and not only that what it produced
/// was right. Every `load` is counted, successful or not.
public final class CountingKeyStore: KeyStore, @unchecked Sendable {
    private let backing = InMemoryKeyStore()
    private let lock = NSLock()
    private var count = 0

    public init() {}

    /// How many times `load` has been called on this store.
    public var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func store(_ secret: WalletSecret, for walletID: String) throws {
        try backing.store(secret, for: walletID)
    }

    public func load(walletID: String) throws -> WalletSecret {
        lock.lock()
        count += 1
        lock.unlock()
        return try backing.load(walletID: walletID)
    }

    public func delete(walletID: String) throws {
        try backing.delete(walletID: walletID)
    }
}
