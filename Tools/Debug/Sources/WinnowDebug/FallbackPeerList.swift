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

        /// Strict about its arguments, because this is a gate: a `--as-of`
        /// whose value the shell ate, an `--asof` or `-as-of` nothing reads,
        /// or the bare instant left behind when the flag itself was lost, must
        /// fail the command rather than quietly turn it into a check of the
        /// committed file against today, whose green answer is to the wrong
        /// question.
        init(_ arguments: [String]) throws {
            let usage: (String) -> any Error = { DebugError.usage("\($0)\n\n\(usageText)") }
            let flags = try WinnowGenerate.flags(["--in", "--as-of"], in: arguments.dropFirst(), usage: usage)
            source = flags["--in"].map { URL(fileURLWithPath: $0) }
                ?? WinnowGenerate.packageRoot.appending(path: FallbackPeerGenerator.Options.defaultOutput)
            guard let text = flags["--as-of"] else {
                now = Date()
                return
            }
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw usage("--as-of needs an ISO 8601 instant such as 2026-09-24T00:00:00Z, not \(text)")
            }
            now = date
        }
    }

    /// What the `// Generation:` line says, told apart from its not being
    /// there at all.
    ///
    /// The two are different faults with different repairs — a file with no
    /// date was written by something that is not the generator, a file whose
    /// date does not parse was hand-edited — and reporting both as "no
    /// `// Generation:` line" names the wrong cause for the second. `nil` for
    /// `text` is the missing line; a non-nil `text` with a nil `date` is the
    /// line that would not parse.
    static func generationLine(in source: String) -> (text: String, date: Date?)? {
        let marker = "// Generation: "
        guard let line = source.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        let text = String(line.dropFirst(marker.count).prefix { $0 != "," })
        return (text, Self.instant(from: text))
    }

    /// The instant on the `// Generation:` line — the same line
    /// `scripts/check-release-policy` reads, so the two gates cannot disagree
    /// about what date the file records. The generator writes it with
    /// `ISO8601DateFormatter`, so it is read back with one.
    static func generationDate(in source: String) -> Date? {
        generationLine(in: source)?.date
    }

    /// Reads what the release gate reads. `dt.datetime.fromisoformat` over
    /// there accepts fractional seconds, and `ISO8601DateFormatter` accepts
    /// them only when it is asked to and then insists on them, so one
    /// formatter cannot read both spellings and the two gates could disagree
    /// about whether one file records a date at all. The generator writes the
    /// first spelling; the second is what a hand edit or a future generator
    /// might leave behind.
    private static func instant(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
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
        guard let line = generationLine(in: source) else {
            return .unusable("no `// Generation:` line, so the list records no date")
        }
        guard let generated = line.date else {
            return .unusable("generation timestamp `\(line.text)` is not an ISO 8601 instant")
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
