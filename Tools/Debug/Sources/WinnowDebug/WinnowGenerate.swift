import WalletCore
import Foundation

/// Release-path generators for the constants the app ships and `swift test`
/// cannot produce: the mainnet fallback-peer list (#161) and a network's
/// header checkpoint (#89), one command each however many networks ship one.
///
/// Both need something `swift test` never has — the live network, or a
/// genesis-validated header file — so as env-gated test suites they never ran.
/// These explicit development commands use WalletCore outside the shipping app.
///
///   winnow-debug generate fallback-peers [--out PATH] [--target 96] [--floor 24]
///   winnow-debug generate checkpoint <headers.bin> [--network N] [--height H] [--vector-out PATH]
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

    /// The `--flag value` pairs after a command's subject, and nothing else.
    ///
    /// A walk that consumes each flag with its value and refuses whatever is
    /// left over: a flag with nothing after it, or with something flag-shaped
    /// where its value belongs; a flag the command does not know, with one
    /// dash or two; a bare word, which is what a `$FLAG` that expanded to
    /// nothing leaves behind; and a flag given twice. Reading any of them as
    /// "not given" is how `check fallback-peers --as-of`, its value eaten by
    /// the shell, came to measure the list against today's clock and answer
    /// green for a question nobody asked, and how a trailing `-h` became a
    /// run rather than help. Only a flag's own values are read after this, so
    /// nothing the walk refused can reach a command. `usage` makes the error,
    /// because `generate` and `check` report a usage fault through different
    /// types with different help text.
    static func flags(_ known: [String], in arguments: ArraySlice<String>,
                      usage: (String) -> any Error = { GenerateError.usage($0) }) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard known.contains(flag) else {
                let fault = flag.hasPrefix("-") ? "unknown option" : "unexpected argument"
                throw usage("\(fault) \(flag); the options are " + known.joined(separator: ", "))
            }
            guard values[flag] == nil else { throw usage("\(flag) given twice") }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].isEmpty, !arguments[next].hasPrefix("-") else {
                throw usage("\(flag) needs a value")
            }
            values[flag] = arguments[next]
            index = arguments.index(after: next)
        }
        return values
    }

    /// `--network`, defaulting to mainnet. Spelled as `BitcoinNetwork`'s own
    /// raw values so adding a network to the enum adds it here too, rather
    /// than leaving a switch behind that silently rejects it. Only the
    /// networks that ship a checkpoint are accepted: regtest begins at zero
    /// on whichever machine runs it, so there is no constant to derive.
    static func network(in flags: [String: String]) throws -> BitcoinNetwork {
        guard let name = flags["--network"] else { return .mainnet }
        guard let network = BitcoinNetwork(rawValue: name),
              BitcoinNetwork.checkpointed.contains(network) else {
            throw GenerateError.usage("unknown network \(name); one of "
                                      + BitcoinNetwork.checkpointed.map(\.rawValue).joined(separator: ", "))
        }
        return network
    }

    static func number<Value: FixedWidthInteger>(_ name: String, in flags: [String: String]) throws -> Value? {
        guard let text = flags[name] else { return nil }
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

      swift run winnow-debug generate checkpoint <headers.bin> [--network N] [--height H] [--vector-out PATH]
          Derive network N's checkpoint at H (default: mainnet, at the shipped
          height) from a genesis-rooted header file for that network, through
          HeaderChain itself; print it as a paste-ready literal; then prove a
          chain started from it agrees with the genesis-rooted chain 2,000
          blocks on. --vector-out writes those 2,000 headers, one per line as
          hex, for HeaderChainTests.
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
