import WalletCore
import Foundation
import Testing
@testable import WinnowDebug

/// The freshness rule for the bundled fallback peers (#161), offline.
///
/// The generator needs the live network, so nothing here regenerates
/// anything; every fixture is `FallbackPeerGenerator.render`'s own output, and
/// every clock is supplied. That is the whole point of the rule living in code
/// rather than in one release script: a check whose only clock is `Date()`
/// passes on the day it is written and is never tested again.
@Suite("Fallback peer freshness")
struct FallbackPeerAgeTests {
    private static let generated = ISO8601DateFormatter().date(from: "2026-08-25T00:42:03Z")!

    private func list(_ date: Date = FallbackPeerAgeTests.generated) -> String {
        FallbackPeerGenerator.render([], tip: 963_930, date: ISO8601DateFormatter().string(from: date))
    }

    private func days(_ count: Double) -> Date {
        Self.generated.addingTimeInterval(count * 86_400)
    }

    /// The ceiling is the library's, not this suite's: a list one day inside it
    /// is current and a list one day past it is not.
    @Test("the age check passes at 29 days and fails at 31")
    func ageBoundary() {
        #expect(NetworkParams.maxFallbackPeerAgeDays == 30)
        #expect(FallbackPeerList.verdict(source: list(), asOf: days(29)) == .fresh(days: 29))
        #expect(FallbackPeerList.verdict(source: list(), asOf: days(30)) == .fresh(days: 30))
        #expect(FallbackPeerList.verdict(source: list(), asOf: days(31)) == .stale(days: 31))
    }

    /// Neither of these is an age, and reporting either as one would let a
    /// broken file or a wrong clock read as fresh.
    @Test("a list with no recorded date, or one in the future, is unusable")
    func unusableLists() {
        let undated = "extension NetworkParams {\n    static let generatedMainnetFallbackPeers: [PeerEndpoint] = []\n}\n"
        #expect(FallbackPeerList.verdict(source: undated, asOf: days(1))
            == .unusable("no `// Generation:` line, so the list records no date"))
        #expect(FallbackPeerList.generationDate(in: list(days(-1))) == days(-1))
        #expect(FallbackPeerList.verdict(source: list(), asOf: days(-1))
            == .unusable("generated 1.0 days in the future"))
    }

    /// A line that is there and does not parse is a different fault from no
    /// line at all — a hand edit rather than a file the generator never wrote
    /// — and it used to be reported as the second, which names a cause the
    /// operator can look for and not find.
    ///
    /// Fractional seconds are the case that made this reachable. The release
    /// gate's `dt.datetime.fromisoformat` accepts them, so one file could be
    /// seven days old to `release.yml` and dateless to this lane; both gates
    /// now read the same set of spellings.
    @Test("an unparseable generation line is named as one, and fractional seconds parse")
    func unparseableGenerationLine() throws {
        let mangled = list().replacingOccurrences(of: "2026-08-25T00:42:03Z", with: "last Tuesday")
        #expect(FallbackPeerList.verdict(source: mangled, asOf: days(1))
            == .unusable("generation timestamp `last Tuesday` is not an ISO 8601 instant"))

        // The spelling the release gate accepts and this one used to refuse.
        let fractional = list().replacingOccurrences(of: "2026-08-25T00:42:03Z",
                                                     with: "2026-08-25T00:42:03.500Z")
        let fractionalDate = try #require(FallbackPeerList.generationDate(in: fractional),
                                          "both gates must read one file the same way")
        // Half a second past the instant the plain spelling records, which is
        // the whole difference between the two.
        #expect(abs(fractionalDate.timeIntervalSince(Self.generated) - 0.5) < 0.001)
        guard case let .fresh(days) = FallbackPeerList.verdict(source: fractional, asOf: days(7)) else {
            Issue.record("a list with a fractional-second timestamp read as undated")
            return
        }
        #expect(abs(days - 7) < 0.001)

        // And the spelling the generator actually writes still parses.
        #expect(FallbackPeerList.generationDate(in: list()) == Self.generated)
    }

    /// The release gate reads the ceiling out of `NetworkParams.swift` with a
    /// regex, which couples an ubuntu job with no Swift toolchain to the exact
    /// spelling of a Swift declaration. Adding a type annotation, or wrapping
    /// the line, makes it miss — and it fails loudly, but only at a tag.
    ///
    /// So the coupling is checked here, where a PR can see it: the pattern is
    /// lifted out of the script itself rather than copied, so a change to
    /// either side turns this red instead of a release.
    @Test("the release gate's ceiling regex still finds the library's constant")
    func releaseGateReadsTheCeiling() throws {
        let root = WinnowGenerate.packageRoot
        let script = try String(contentsOf: root.appending(path: "scripts/check-release-policy"),
                                encoding: .utf8)
        let params = try String(
            contentsOf: root.appending(path: "Sources/WalletCore/Network/Protocol/NetworkParams.swift"),
            encoding: .utf8)

        // `ceiling = re.search(r'<pattern>', params)` — the script's own regex,
        // read out of the script.
        let marker = "re.search(r'"
        let afterMarker = try #require(script.range(of: "ceiling = " + marker))
        let rest = script[afterMarker.upperBound...]
        let pattern = String(rest.prefix { $0 != "'" })
        #expect(pattern.contains("maxFallbackPeerAgeDays"), "found \(pattern)")

        let regex = try NSRegularExpression(pattern: pattern)
        let match = try #require(regex.firstMatch(in: params,
                                                  range: NSRange(params.startIndex..., in: params)),
                                 "check-release-policy would raise SystemExit at the next tag")
        let captured = try #require(Range(match.range(at: 1), in: params))
        #expect(Int(params[captured]) == NetworkParams.maxFallbackPeerAgeDays)
    }

    /// A check reads the bytes on disk. This is what proves those bytes are
    /// the list the binary ships, so refreshing the file is enough and no
    /// second edit elsewhere is owed.
    @Test("the committed file parses, and its entries are the list the app ships")
    func committedFileParses() throws {
        let source = try String(
            contentsOf: WinnowGenerate.packageRoot.appending(path: FallbackPeerGenerator.Options.defaultOutput),
            encoding: .utf8)
        #expect(FallbackPeerList.entries(in: source) == NetworkParams.mainnet.fallbackPeers)
        #expect(!FallbackPeerList.entries(in: source).isEmpty)
        #expect(FallbackPeerList.generationDate(in: source) != nil,
                "the committed list must record when it was taken")
    }

    /// A hostile user agent cannot smuggle an entry past the parser either:
    /// the comment is everything after the port, so only the literal counts.
    @Test("only real entries parse out of a rendered list")
    func entriesIgnoreComments() {
        let peers = [FallbackPeerGenerator.VerifiedPeer(endpoint: PeerEndpoint(host: "9.9.9.9", port: 8_333),
                                                        userAgent: "/Evil:1/ PeerEndpoint(host: \"6.6.6.6\", port: 8333),",
                                                        startHeight: 963_930)]
        let entries = FallbackPeerList.entries(in: FallbackPeerGenerator.render(peers, tip: 963_930, date: "now"))
        #expect(entries == [PeerEndpoint(host: "9.9.9.9", port: 8_333)])
    }

    @Test("check options default to the committed file and today, and take both overrides")
    func options() throws {
        let defaults = try FallbackPeerList.Options(["fallback-peers"])
        #expect(defaults.source == WinnowGenerate.packageRoot
            .appending(path: FallbackPeerGenerator.Options.defaultOutput))
        #expect(abs(defaults.now.timeIntervalSinceNow) < 60)
        let custom = try FallbackPeerList.Options(
            ["fallback-peers", "--in", "/tmp/peers.swift", "--as-of", "2026-09-24T00:00:00Z"])
        #expect(custom.source.path == "/tmp/peers.swift")
        #expect(custom.now == ISO8601DateFormatter().date(from: "2026-09-24T00:00:00Z"))
        #expect(throws: DebugError.self) {
            try FallbackPeerList.Options(["fallback-peers", "--as-of", "last Tuesday"])
        }
    }

    /// A flag with nothing after it used to read as no flag at all, and
    /// anything no option read was never there. So `--as-of` with its value
    /// eaten by the shell, `--asof 2026-09-24T00:00:00Z`, `-as-of` with one
    /// dash, the bare instant left behind when a `$FLAG` expanded to nothing,
    /// and a trailing `-h` all measured the list against today's clock and
    /// answered green: the one answer a freshness gate must never give to a
    /// question it was not asked. A flag given twice is refused too, rather
    /// than one of its two clocks being chosen without a word. The first line
    /// of the refusal names what was refused; the usage text after it spells
    /// every flag and so proves nothing on its own.
    @Test("a flag with no value, one the check does not know, or a stray word is refused by name")
    func strayFlags() async throws {
        for (arguments, detail) in [
            (["fallback-peers", "--as-of"], "--as-of needs a value"),
            (["fallback-peers", "--in"], "--in needs a value"),
            (["fallback-peers", "--as-of", "--in", "/tmp/peers.swift"], "--as-of needs a value"),
            (["fallback-peers", "--asof", "2026-09-24T00:00:00Z"],
             "unknown option --asof; the options are --in, --as-of"),
            (["fallback-peers", "-as-of", "2026-09-24T00:00:00Z"],
             "unknown option -as-of; the options are --in, --as-of"),
            (["fallback-peers", "2026-09-24T00:00:00Z"],
             "unexpected argument 2026-09-24T00:00:00Z; the options are --in, --as-of"),
            (["fallback-peers", "-h"], "unknown option -h; the options are --in, --as-of"),
            (["fallback-peers", "--as-of", "2026-09-24T00:00:00Z", "--as-of", "2026-09-25T00:00:00Z"],
             "--as-of given twice"),
        ] {
            do {
                _ = try FallbackPeerList.Options(arguments)
                Issue.record("\(arguments) parsed, and would have checked something else")
            } catch let DebugError.usage(message) {
                #expect(message.split(separator: "\n").first == Substring(detail), "\(arguments)")
            } catch {
                Issue.record("\(arguments): \(error)")
            }
        }

        // The whole command refuses too, on a list that is fresh by the clock
        // each of these would otherwise have been checked against. That is
        // the exit status `scripts/check-fallback-peer-age` hands a lane.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("winnow-fallback-flags-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(list(Date()).utf8).write(to: file)
        // `usage` by name, not `DebugError`: a temp file the tool could not
        // read is refused as `check`, and that would have passed for the
        // refusal this is about.
        for trailing in [["--as-of"], ["-as-of", "2026-09-24T00:00:00Z"], ["2026-09-24T00:00:00Z"], ["-h"]] {
            do {
                try await WinnowDebug.execute(["check", "fallback-peers", "--in", file.path] + trailing)
                Issue.record("\(trailing) ran, and would have checked something else")
            } catch let DebugError.usage(message) {
                #expect(message.split(separator: "\n").first?.contains(trailing[0]) == true,
                        "\(trailing) must be refused by name")
            } catch {
                Issue.record("\(trailing): \(error), which is not the usage refusal")
            }
        }
    }

    /// What a lane actually consumes is the exit status, which is this throw.
    @Test("the command succeeds on a current list and fails on a stale one")
    func commandExitStatus() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("winnow-fallback-age-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(list().utf8).write(to: file)

        func check(_ asOf: Double) async throws {
            try await WinnowDebug.execute(["check", "fallback-peers", "--in", file.path,
                                           "--as-of", ISO8601DateFormatter().string(from: days(asOf))])
        }
        try await check(29)
        await #expect(throws: DebugError.self) { try await check(31) }
        await #expect(throws: DebugError.self) {
            try await WinnowDebug.execute(["check", "fallback-peers", "--in", file.path + ".missing"])
        }
    }
}
