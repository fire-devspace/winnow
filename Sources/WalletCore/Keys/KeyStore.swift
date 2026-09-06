import Foundation
import Security

public enum KeyStoreError: LocalizedError, Equatable {
    case notFound(walletID: String)
    case alreadyExists(walletID: String)
    case malformedSecret
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .notFound(walletID):
            "The protected key for wallet \(walletID) is missing from this device."
        case let .alreadyExists(walletID):
            "This device already contains a protected key for wallet \(walletID)."
        case .malformedSecret:
            "The protected wallet key is damaged or has an unsupported format."
        case let .keychain(status):
            "The device could not store the protected wallet key (\(SecCopyErrorMessageString(status, nil) as String? ?? "keychain status \(status)"))."
        }
    }
}

/// The root secret of a wallet, as held by a `KeyStore`.
public enum WalletSecret: Equatable, Sendable {
    /// BIP39 mnemonic sentence (single spaces, checksummed).
    case mnemonic(String)
    /// BIP32 master extended private key, Base58Check (xprv/tprv).
    case masterKey(String)

    /// Tagged text encoding: a header line (`mnemonic` / `xprv`) + payload line.
    /// Versionable and inspectable; the bytes are what lands in the keychain.
    public var serialized: Data {
        switch self {
        case let .mnemonic(words): Data("mnemonic\n\(words)".utf8)
        case let .masterKey(xprv): Data("xprv\n\(xprv)".utf8)
        }
    }

    public init(serialized: Data) throws {
        let text = String(decoding: serialized, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 2 else { throw KeyStoreError.malformedSecret }
        switch lines[0] {
        case "mnemonic": self = .mnemonic(String(lines[1]))
        case "xprv": self = .masterKey(String(lines[1]))
        default: throw KeyStoreError.malformedSecret
        }
    }
}

/// Secret storage for wallets, keyed by wallet ID. Implementations must keep
/// secrets on the device and out of any cloud sync/backup (docs/mobile.md §5:
/// the keys are the wallet).
public protocol KeyStore: Sendable {
    /// Stores `secret` under `walletID`; throws `alreadyExists` if occupied.
    func store(_ secret: WalletSecret, for walletID: String) throws
    /// Loads the secret for `walletID`; throws `notFound` if absent.
    func load(walletID: String) throws -> WalletSecret
    /// Deletes the secret for `walletID`; deleting an absent ID is a no-op.
    func delete(walletID: String) throws
}

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
