import BitcoinCore
import BitcoinP2P
import Foundation

/// Master switch: the differential suite talks to the dev custom-signet node
/// ONLY when WINNOW_DIFF=1 is set. Default `swift test` runs skip cleanly
/// and never touch the network or the node.
let diffEnabled = ProcessInfo.processInfo.environment["WINNOW_DIFF"] == "1"

/// The well-known BIP39 all-"abandon" mnemonic — the harness never holds
/// real funds; this is a disposable signet.
let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

func testMaster() throws -> HDKey {
    try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
}

/// Thread-safe sink for FilterSync matches.
final class MatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BlockMatch] = []

    var matches: [BlockMatch] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ match: BlockMatch) {
        lock.lock()
        stored.append(match)
        lock.unlock()
    }
}

/// Temporary file URL under a per-run directory.
func tempFileURL(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("winnow-diff-tests-\(UUID().uuidString)")
        .appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    return url
}

extension Data {
    /// Bitcoin compactSize varint (BitcoinP2P's `appendCompactSize` is
    /// module-internal and clashes under @testable double-import).
    mutating func appendVarInt(_ value: UInt64) {
        switch value {
        case ..<0xFD:
            append(UInt8(value))
        case ...0xFFFF:
            append(0xFD)
            Swift.withUnsafeBytes(of: UInt16(value).littleEndian) { append(contentsOf: $0) }
        case ...0xFFFF_FFFF:
            append(0xFE)
            Swift.withUnsafeBytes(of: UInt32(value).littleEndian) { append(contentsOf: $0) }
        default:
            append(0xFF)
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }
}
