import WalletCore
import Foundation

/// The committed fallback list (#161) read back as data: when it was
/// generated, and which endpoints it holds.
///
/// `FallbackPeerGenerator` writes the file and needs the live network to do
/// it. This reads the file and needs nothing, which is the difference that
/// matters. The age rule can then be asked on any cadence, by any lane, and
/// with any clock — including a lane that only ever checks out a pinned
/// revision and so never reaches the release tag `scripts/check-release-policy`
/// is wired to.
///
/// The ceiling is `NetworkParams.maxFallbackPeerAgeDays`, in the library
/// beside the list it governs. Nothing here decides what "too old" means; it
/// only measures and reports.
enum FallbackPeerList {
    /// What a freshness check found.
    ///
    /// Both answers carry the measured age, because a caller that has to say
    /// "four days over" needs the number the verdict was reached with, not
    /// just the verdict.
    enum Verdict: Equatable {
        case fresh(days: Double)
        case stale(days: Double)
        /// Not usable as a generated list: no `// Generation:` line, an
        /// instant that does not parse, or one in the future — which is a
        /// wrong clock or a hand edit, and never an age.
        case unusable(String)
    }

    struct Options {
        let source: URL
        /// The clock the check runs against. Injectable because a rule whose
        /// only clock is `Date()` can be tested on the day it is written and
        /// never again.
        let now: Date

        init(_ arguments: [String]) throws {
            source = WinnowGenerate.option("--in", in: arguments).map { URL(fileURLWithPath: $0) }
                ?? WinnowGenerate.packageRoot.appending(path: FallbackPeerGenerator.Options.defaultOutput)
            guard let text = WinnowGenerate.option("--as-of", in: arguments) else {
                now = Date()
                return
            }
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw DebugError.usage("--as-of needs an ISO 8601 instant such as "
                                       + "2026-09-24T00:00:00Z, not \(text)\n\n\(usageText)")
            }
            now = date
        }
    }

    /// The instant on the `// Generation:` line — the same line
    /// `scripts/check-release-policy` reads, so the two gates cannot disagree
    /// about what date the file records. The generator writes it with
    /// `ISO8601DateFormatter`, so it is read back with one.
    static func generationDate(in source: String) -> Date? {
        let marker = "// Generation: "
        guard let line = source.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        return ISO8601DateFormatter().date(from: String(line.dropFirst(marker.count).prefix { $0 != "," }))
    }

    /// Every endpoint the file compiles in, read out of the source text.
    ///
    /// Parsing the bytes rather than reading `NetworkParams.mainnet` is the
    /// point: a check runs against the file on disk, and this is what lets a
    /// test prove those bytes are the list the binary ships.
    static func entries(in source: String) -> [PeerEndpoint] {
        source.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].hasSuffix("PeerEndpoint(host: "),
                  parts[2].hasPrefix(", port: "),
                  let port = UInt16(parts[2].dropFirst(", port: ".count).prefix(while: \.isNumber))
            else { return nil }
            return PeerEndpoint(host: String(parts[1]), port: port)
        }
    }

    static func verdict(source: String, asOf now: Date) -> Verdict {
        guard let generated = generationDate(in: source) else {
            return .unusable("no `// Generation:` line, so the list records no date")
        }
        let days = now.timeIntervalSince(generated) / 86_400
        guard days >= 0 else {
            return .unusable("generated \(rounded(-days)) days in the future")
        }
        return days <= Double(NetworkParams.maxFallbackPeerAgeDays)
            ? .fresh(days: days) : .stale(days: days)
    }

    /// `winnow-debug check fallback-peers`, also reachable as
    /// `scripts/check-fallback-peer-age`. The exit status is the answer: zero
    /// when the list is current, non-zero when it is stale or unreadable.
    static func execute(_ arguments: [String]) throws {
        guard let subject = arguments.first, !["help", "--help", "-h"].contains(subject) else {
            return print(usageText)
        }
        guard subject == "fallback-peers" else {
            throw DebugError.usage("unknown check \(subject)\n\n\(usageText)")
        }
        let options = try Options(arguments)
        guard let source = try? String(contentsOf: options.source, encoding: .utf8) else {
            throw DebugError.check("\(options.source.path): no readable generated list here")
        }
        let ceiling = NetworkParams.maxFallbackPeerAgeDays
        switch verdict(source: source, asOf: options.now) {
        case let .fresh(days):
            print("fallback peers: \(entries(in: source).count) entries, "
                  + "\(rounded(days)) days old, ceiling \(ceiling)")
        case let .stale(days):
            throw DebugError.check("fallback peers are \(rounded(days)) days old, past the "
                                   + "\(ceiling)-day ceiling: run scripts/generate-fallback-peers, "
                                   + "keep its log, and commit the refreshed list")
        case let .unusable(reason):
            throw DebugError.check("\(options.source.path): \(reason)")
        }
    }

    static func rounded(_ days: Double) -> String { String(format: "%.1f", days) }

    static let usageText = """
    Winnow release-data checks

      swift run winnow-debug check fallback-peers [--in PATH] [--as-of ISO8601]
          Exit 0 when the committed fallback-peer list is at most
          NetworkParams.maxFallbackPeerAgeDays old, and non-zero when it is
          older, records no generation date, or records one in the future.
          --as-of fixes the clock; --in names a file other than the committed
          one. Reads the file and nothing else: no network, no toolchain state.
    """
}
