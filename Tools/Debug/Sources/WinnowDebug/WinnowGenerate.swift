import WalletCore
import Foundation

/// Release-path generators for two constants the app ships: the mainnet
/// fallback-peer list (#161) and the mainnet header checkpoint (#89).
///
/// Both need something `swift test` never has — the live network, or a 77 MB
/// genesis-validated header file — so as env-gated test suites they never ran.
/// These explicit development commands use WalletCore outside the shipping app.
///
///   winnow-debug generate fallback-peers [--out PATH] [--target 96] [--floor 24]
///   winnow-debug generate checkpoint <headers.bin> [--height H] [--vector-out PATH]
enum WinnowGenerate {
    static func execute(_ arguments: [String]) async throws {
        guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
            return usage()
        }
        switch command {
        case "fallback-peers":
            let options = try FallbackPeerGenerator.Options(arguments)
            try await FallbackPeerGenerator.run(options)
        case "checkpoint":
            let options = try CheckpointGenerator.Options(arguments)
            try await CheckpointGenerator.run(options)
        default:
            throw GenerateError.usage("unknown command \(command)")
        }
    }

    /// Tools/Debug/Sources/WinnowDebug/… → the package root is five
    /// levels up. Taken from `#filePath` at compile time, as the generator test
    /// this replaces did, so the default output lands in this checkout whatever
    /// directory the tool is run from.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func number<Value: FixedWidthInteger>(_ name: String, in arguments: [String]) throws -> Value? {
        guard let text = option(name, in: arguments) else { return nil }
        guard let value = Value(text) else { throw GenerateError.usage("\(name) needs a whole number, not \(text)") }
        return value
    }

    static func usage() {
        print(usageText)
    }

    static let usageText = """
    Winnow release-path generators

      swift run winnow-debug generate fallback-peers [--out PATH] [--target 96] [--floor 24]
          Resolve the mainnet DNS seeds, dial candidates with the app's own
          PeerConnection, keep a /16-spread selection near the median tip and
          rewrite Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift.

      swift run winnow-debug generate checkpoint <headers.bin> [--height H] [--vector-out PATH]
          Derive the mainnet checkpoint at H (default: the shipped height) from a
          genesis-rooted header file, through HeaderChain itself; print it as a
          paste-ready literal; then prove a chain started from it agrees with the
          genesis-rooted chain 2,000 blocks on. --vector-out writes those 2,000
          headers, one per line as hex, for HeaderChainTests.
    """
}

enum GenerateError: LocalizedError {
    case usage(String)
    case thinList(String)
    case badSource(String)
    case divergence(String)

    var errorDescription: String? {
        switch self {
        case let .usage(detail): "\(detail)\n\n\(WinnowGenerate.usageText)"
        case let .thinList(detail): "\(detail) — refusing to ship a thin list"
        case let .badSource(detail): "unusable header file: \(detail)"
        case let .divergence(detail): "checkpoint disagreement: \(detail)"
        }
    }
}
