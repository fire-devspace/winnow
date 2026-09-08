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

/// The spending secret of a wallet, as held by a `KeyStore`.
public enum WalletSecret: Equatable, Sendable {
    /// BIP39 mnemonic sentence (single spaces, checksummed).
    case mnemonic(String)
    /// BIP32 master extended private key, Base58Check (xprv/tprv).
    case masterKey(String)
    /// BIP32 account extended private key at the descriptor's own origin path
    /// (m/86'/coin'/account'), Base58Check, with the fingerprint of the master
    /// key it was derived from.
    ///
    /// This fork adds the case for an embedder that derives the account key in
    /// its own key service and hands the library nothing above it; upstream
    /// stores a root secret and has no way to reach this case. The wallet ID
    /// and every PSBT origin are still the master fingerprint, which an
    /// account key cannot supply on its own: an extended key records only its
    /// parent's fingerprint, and the parent here is m/86'/coin', not the
    /// master. So the fingerprint travels beside the key.
    case accountKey(xprv: String, masterFingerprint: UInt32)

    /// Tagged text encoding: a header line (`mnemonic` / `xprv` / `account`)
    /// and its payload lines. Versionable and inspectable; the bytes are what
    /// lands in the keychain.
    public var serialized: Data {
        switch self {
        case let .mnemonic(words): Data("mnemonic\n\(words)".utf8)
        case let .masterKey(xprv): Data("xprv\n\(xprv)".utf8)
        case let .accountKey(xprv, fingerprint):
            Data("account\n\(String(format: "%08x", fingerprint))\n\(xprv)".utf8)
        }
    }

    public init(serialized: Data) throws {
        let text = String(decoding: serialized, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first else { throw KeyStoreError.malformedSecret }
        switch header {
        case "mnemonic" where lines.count == 2: self = .mnemonic(String(lines[1]))
        case "xprv" where lines.count == 2: self = .masterKey(String(lines[1]))
        case "account" where lines.count == 3:
            // Fixed-width lowercase hex, the spelling every wallet ID and
            // descriptor origin in this library uses, so a stored secret and
            // the descriptor beside it cannot disagree by formatting alone.
            guard lines[1].count == 8, lines[1].allSatisfy(\.isHexDigit),
                  let fingerprint = UInt32(lines[1], radix: 16)
            else { throw KeyStoreError.malformedSecret }
            self = .accountKey(xprv: String(lines[2]), masterFingerprint: fingerprint)
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
