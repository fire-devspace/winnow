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
