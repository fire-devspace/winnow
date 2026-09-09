import Foundation
import Security

public enum KeyStoreError: LocalizedError, Equatable {
    case notFound(walletID: String)
    case alreadyExists(walletID: String)
    case malformedSecret
    /// A stored secret whose header names a format version this build does not
    /// know. Kept apart from `malformedSecret` on purpose: the bytes are
    /// intact and a newer build reads them, so an older build must say which
    /// version it found rather than report damage and invite someone to erase
    /// a key that is the only copy.
    case unsupportedSecretVersion(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .notFound(walletID):
            "The protected key for wallet \(walletID) is missing from this device."
        case let .alreadyExists(walletID):
            "This device already contains a protected key for wallet \(walletID)."
        case .malformedSecret:
            "The protected wallet key is damaged or has an unsupported format."
        case let .unsupportedSecretVersion(header):
            "The protected wallet key was written by a newer version of this app (\(header)). Update to open this wallet; the key itself is intact."
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

    /// The account encoding's header, version included. Upstream's two headers
    /// are bare words and stay that way, because a build that has shipped them
    /// is already reading them; this case has shipped nowhere, so it can carry
    /// the version from its first byte and an older build can refuse a shape
    /// it does not know instead of guessing at the lines beneath.
    static let accountHeaderPrefix = "account/"
    static let accountHeader = accountHeaderPrefix + "1"

    /// The version tag of an account header, and nothing else: the header
    /// cut at the first character that is not a letter, a digit or a slash,
    /// and at twenty-four characters. What an error may say about a blob it
    /// could not read, when the "header" is the whole blob because its
    /// separators were not newlines.
    static func versionTag(of header: String) -> String {
        String(header.prefix { $0.isLetter || $0.isNumber || $0 == "/" }.prefix(24))
    }

    /// Tagged text encoding: a header line (`mnemonic` / `xprv` / `account/1`)
    /// and its payload lines. Versionable and inspectable; the bytes are what
    /// lands in the keychain.
    public var serialized: Data {
        switch self {
        case let .mnemonic(words): Data("mnemonic\n\(words)".utf8)
        case let .masterKey(xprv): Data("xprv\n\(xprv)".utf8)
        case let .accountKey(xprv, fingerprint):
            Data("\(Self.accountHeader)\n\(String(format: "%08x", fingerprint))\n\(xprv)".utf8)
        }
    }

    public init(serialized: Data) throws {
        let text = String(decoding: serialized, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { throw KeyStoreError.malformedSecret }
        let header = String(first)
        switch header {
        case "mnemonic" where lines.count == 2: self = .mnemonic(String(lines[1]))
        case "xprv" where lines.count == 2: self = .masterKey(String(lines[1]))
        // The line count is checked inside this case rather than beside the
        // header, so a known version carrying the wrong number of lines reads
        // as damage. Falling through to the version arm would report it as a
        // version nobody supports, which is the one thing it is not.
        case Self.accountHeader:
            // Fixed-width lowercase hex, the spelling every wallet ID and
            // descriptor origin in this library uses, so a stored secret and
            // the descriptor beside it cannot disagree by formatting alone.
            // `serialized` writes lowercase, so an uppercase digit did not come
            // from this library: reading it would make the same key have two
            // encodings, and a comparison of stored bytes say they differ.
            guard lines.count == 3, lines[1].count == 8,
                  lines[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let fingerprint = UInt32(lines[1], radix: 16)
            else { throw KeyStoreError.malformedSecret }
            self = .accountKey(xprv: String(lines[2]), masterFingerprint: fingerprint)
        case _ where header.hasPrefix(Self.accountHeaderPrefix):
            // Recognisably an account secret, in a version this build has no
            // rules for. Naming it is the whole point of the tag, and the
            // TAG is all the error carries: the header is whatever came
            // before the first newline, which is the whole blob, fingerprint
            // and key included, when the separators are not newlines at all.
            throw KeyStoreError.unsupportedSecretVersion(Self.versionTag(of: header))
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
