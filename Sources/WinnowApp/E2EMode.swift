import BitcoinCore
import BitcoinP2P
import Foundation
import Security

/// Launch-environment hooks for the XCUITest end-to-end suite (UITests/).
/// Entirely inert unless the app is launched with WINNOW_E2E=1: a normal
/// launch never reads any of this and behaves exactly as before.
///
/// Test mode:
/// - redirects Application Support storage to a throwaway `BTCSwiftE2E-<run>`
///   directory and the Keychain to a dedicated service, so a real wallet's
///   state is never touched;
/// - points the sync stack at a local custom-signet node (BIP325 challenge +
///   manual peer) instead of the public signet;
/// - can fix the wallet entropy (or full mnemonic) so screenshots are
///   reproducible.
struct E2EMode {
    /// Namespace for storage ("main", "import", …) — each test scenario that
    /// needs a fresh wallet gets its own run id.
    let runID: String
    /// "host:port" of the local node, preconfigured as the manual peer.
    let peer: String?
    /// The custom signet's BIP325 challenge.
    let challenge: Data?
    /// Fixed wallet entropy for reproducible addresses/screenshots.
    let entropy: Data?
    /// Wipe this run's storage and the test Keychain namespace on launch.
    let reset: Bool
    /// Text the app puts on its own pasteboard at boot — drives the Paste
    /// buttons (send destination, import JSON) without cross-app paste
    /// consent prompts.
    let clipboard: String?

    static let keychainService = "org.btc-swift.wallet.e2e"

    static var current: E2EMode? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WINNOW_E2E"] == "1" else { return nil }
        let entropy: Data?
        if let hex = environment["WINNOW_E2E_ENTROPY"] {
            entropy = Data(hex: hex)
        } else if let mnemonic = environment["WINNOW_E2E_MNEMONIC"] {
            entropy = try? entropyFrom(mnemonic: mnemonic)
        } else {
            entropy = nil
        }
        return E2EMode(runID: environment["WINNOW_E2E_RUN"] ?? "main",
                       peer: environment["WINNOW_E2E_PEER"],
                       challenge: environment["WINNOW_E2E_CHALLENGE"].flatMap { Data(hex: $0) },
                       entropy: entropy,
                       reset: environment["WINNOW_E2E_RESET"] == "1",
                       clipboard: environment["WINNOW_E2E_CLIPBOARD"])
    }

    /// The Application Support subdirectory used instead of "BTCSwift".
    var storageDirectoryName: String { "BTCSwiftE2E-\(runID)" }

    /// The sync stack's network parameters: the custom signet when a
    /// challenge was injected, else the stock network params.
    var networkParams: NetworkParams? {
        challenge.map { .customSignet(challenge: $0, defaultPort: 38_401) }
    }

    /// `WINNOW_E2E_RESET=1`: drop this run's storage directory and every
    /// Keychain entry in the test namespace.
    func wipeIfRequested() {
        guard reset else { return }
        SecItemDelete([kSecClass: kSecClassGenericPassword,
                       kSecAttrService: Self.keychainService] as CFDictionary)
        if let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true) {
            try? FileManager.default.removeItem(at: base.appending(path: storageDirectoryName,
                                                                   directoryHint: .isDirectory))
        }
    }

    /// Mnemonic sentence → entropy (BIP39 decode; the injected mnemonic is
    /// reproduced exactly by the wallet creation screen).
    private static func entropyFrom(mnemonic: String) throws -> Data {
        let words = mnemonic.split(separator: " ").map(String.init)
        var bits: [UInt8] = []
        for word in words {
            guard let index = BIP39.wordlist.firstIndex(of: word) else {
                throw BIP39Error.wordNotInWordlist(word)
            }
            bits += (0 ..< 11).reversed().map { UInt8((index >> $0) & 1) }
        }
        let checksumLength = words.count / 3
        let entropyLength = (bits.count - checksumLength) / 8
        var entropy = Data(repeating: 0, count: entropyLength)
        for i in 0 ..< entropyLength * 8 where bits[i] == 1 {
            entropy[i / 8] |= 1 << UInt8(7 - (i % 8))
        }
        return entropy
    }
}
