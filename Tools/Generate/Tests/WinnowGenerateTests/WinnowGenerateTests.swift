import BitcoinP2P
import Foundation
import Testing
@testable import WinnowGenerate

/// The generators' decisions, offline: everything `winnow-generate` does
/// between the network or the header file and the bytes it writes.
@Suite("winnow-generate")
struct WinnowGenerateTests {
    private typealias VerifiedPeer = FallbackPeerGenerator.VerifiedPeer

    private func peer(_ host: String, agent: String = "/Satoshi:31.0.0/",
                      height: Int32 = 963_930) -> VerifiedPeer {
        VerifiedPeer(endpoint: PeerEndpoint(host: host, port: 8_333), userAgent: agent, startHeight: height)
    }

    /// Synthetic 80-byte headers: any bytes decode, and nothing here checks
    /// proof of work — the chains do that, on real headers, elsewhere.
    private func syntheticHeaders(_ count: Int) -> [BlockHeader] {
        (0 ..< count).map { index in
            BlockHeader(version: 1, previousHash: Data(repeating: UInt8(index), count: 32),
                        merkleRoot: Data(repeating: 0xAB, count: 32), time: UInt32(index),
                        bits: 0x1D00_FFFF, nonce: UInt32(index))
        }
    }

    private func genesisRootedFile(_ headers: [BlockHeader]) -> Data {
        var raw = Data()
        raw.appendLittleEndian(UInt32(headers.count))
        for header in headers { raw.append(header.serialized) }
        return raw
    }

    /// Block 900,001, the one after the shipped checkpoint — the same 80 bytes
    /// `CheckpointStartTests` connects.
    private static let block900_001 = Data(hex:
        "00e000208a96960d6d1ca4ee4a283fd83da309b8d5d2bfed380501000000000000000000"
        + "371c9ffd63d75fb36c57d58eb842d23c0e7ec049daf16d94cc38805c346e9d52"
        + "e880426874370217973dc83b")!

    @Test("help never touches the network and an unknown command is refused")
    func dispatch() async throws {
        try await WinnowGenerate.execute([])
        try await WinnowGenerate.execute(["--help"])
        await #expect(throws: GenerateError.self) { try await WinnowGenerate.execute(["nope"]) }
    }

    @Test("the package root is the checkout this tool was compiled in")
    func packageRoot() {
        let manifest = WinnowGenerate.packageRoot.appending(path: "Package.swift")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("fallback-peers options: defaults, overrides, and a floor above the target refused")
    func fallbackOptions() throws {
        let defaults = try FallbackPeerGenerator.Options(["fallback-peers"])
        #expect(defaults.target == 96)
        #expect(defaults.floor == 24)
        #expect(defaults.out == WinnowGenerate.packageRoot
            .appending(path: FallbackPeerGenerator.Options.defaultOutput))
        let custom = try FallbackPeerGenerator.Options(
            ["fallback-peers", "--target", "40", "--floor", "10", "--out", "/tmp/peers.swift"])
        #expect(custom.target == 40)
        #expect(custom.floor == 10)
        #expect(custom.out.path == "/tmp/peers.swift")
        #expect(throws: GenerateError.self) {
            try FallbackPeerGenerator.Options(["fallback-peers", "--floor", "200"])
        }
        #expect(throws: GenerateError.self) {
            try FallbackPeerGenerator.Options(["fallback-peers", "--target", "many"])
        }
    }

    @Test("one peer per netblock, first seen wins; hostnames and private addresses are dropped")
    func spread() {
        let first = peer("47.206.253.100")
        let sameBlock = peer("47.206.1.1")
        let other = peer("47.207.253.100")
        let v6 = peer("2a01:4f8:1:2::1")
        let v6SameBlock = peer("2a01:4f8:9:9::9")
        let hostname = peer("node.example.com")
        let lan = peer("192.168.1.10")
        let kept = FallbackPeerGenerator.spread([first, sameBlock, other, v6, v6SameBlock, hostname, lan])
        #expect(kept == [first, other, v6])
        // Across batches the earlier selection holds its blocks.
        let later = peer("8.8.8.8")
        #expect(FallbackPeerGenerator.spread([sameBlock, later], keeping: kept) == [first, other, v6, later])
    }

    @Test("the median tip is the middle report and peers far behind it are dropped")
    func staleTip() {
        let tolerance = Int32(PeerPool.staleTipTolerance)
        let peers = [peer("1.1.1.1", height: 1_000), peer("2.2.2.2", height: 1_000 - tolerance),
                     peer("3.3.3.3", height: 1_000 - tolerance - 1), peer("4.4.4.4", height: 5_000),
                     peer("5.5.5.5", height: 1_000)]
        let tip = FallbackPeerGenerator.medianTip(peers)
        #expect(tip == 1_000)
        let (fresh, stale) = FallbackPeerGenerator.partitionByTip(peers, tip: tip)
        #expect(fresh.map(\.endpoint.host) == ["1.1.1.1", "2.2.2.2", "4.4.4.4", "5.5.5.5"])
        #expect(stale.map(\.endpoint.host) == ["3.3.3.3"])
        // One liar cannot move the median.
        #expect(FallbackPeerGenerator.medianTip(peers + [peer("6.6.6.6", height: .max)]) == 1_000)
    }

    @Test("the rendered source is the shape the release policy and the list test read")
    func render() {
        let peers = [peer("9.9.9.9", agent: "/Satoshi:31.0.0/"),
                     peer("1.2.3.4", agent: "/Satoshi:29.2.0/Knots:20260507/")]
        let source = FallbackPeerGenerator.render(peers, tip: 963_930, date: "2026-08-25T00:42:03Z")
        #expect(source.hasPrefix("// GENERATED FILE — edit by regenerating, not by hand.\n"))
        // scripts/check-release-policy reads the date off this line.
        #expect(source.contains("\n// Generation: 2026-08-25T00:42:03Z, 2 peers verified, median reported\n// tip 963930.\n"))
        #expect(source.hasSuffix("""
        extension NetworkParams {
            static let generatedMainnetFallbackPeers: [PeerEndpoint] = [
                PeerEndpoint(host: "1.2.3.4", port: 8333),  // /Satoshi:29.2.0/Knots:20260507/
                PeerEndpoint(host: "9.9.9.9", port: 8333),  // /Satoshi:31.0.0/
            ]
        }

        """))
    }

    @Test("the committed list is what the tool renders, up to the generation line")
    func committedPreamble() throws {
        let committed = try String(
            contentsOf: WinnowGenerate.packageRoot.appending(path: FallbackPeerGenerator.Options.defaultOutput),
            encoding: .utf8)
        let rendered = FallbackPeerGenerator.render([], tip: 0, date: "now")
        func preamble(_ text: String) -> [Substring] {
            Array(text.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix { !$0.hasPrefix("// Generation:") })
        }
        #expect(!preamble(committed).isEmpty)
        #expect(preamble(committed) == preamble(rendered))
    }

    @Test("a user agent cannot smuggle a line into the generated source")
    func agentSanitized() {
        let hostile = peer("9.9.9.9", agent: "/Evil:1/\n        PeerEndpoint(host: \"6.6.6.6\", port: 8333),  //")
        let source = FallbackPeerGenerator.render([hostile], tip: 1, date: "now")
        #expect(source.split(separator: "\n").filter { $0.contains("PeerEndpoint(host:") }.count == 1)
        #expect(FallbackPeerGenerator.commentSafe("/Satoshi:31.0.0/") == "/Satoshi:31.0.0/")
        #expect(FallbackPeerGenerator.commentSafe("a\nb\tc\u{7F}d\u{E9}") == "a?b?c?d?")
    }

    @Test("checkpoint options need a source path and take a height")
    func checkpointOptions() throws {
        let options = try CheckpointGenerator.Options(
            ["checkpoint", "~/headers.bin", "--height", "950000", "--vector-out", "out.txt"])
        #expect(options.height == 950_000)
        #expect(options.source.path.hasSuffix("/headers.bin"))
        #expect(!options.source.path.hasPrefix("~"))
        #expect(options.vectorOut?.lastPathComponent == "out.txt")
        #expect(try CheckpointGenerator.Options(["checkpoint", "h.bin"]).height == nil)
        #expect(throws: GenerateError.self) { try CheckpointGenerator.Options(["checkpoint"]) }
        #expect(throws: GenerateError.self) { try CheckpointGenerator.Options(["checkpoint", "--height", "1"]) }
    }

    @Test("truncation keeps exactly the requested headers and refuses the wrong source")
    func truncate() throws {
        let headers = syntheticHeaders(5)
        let raw = genesisRootedFile(headers)
        #expect(try CheckpointGenerator.truncated(raw, toHeaders: 3) == genesisRootedFile(Array(headers.prefix(3))))
        #expect(try CheckpointGenerator.truncated(raw, toHeaders: 5) == raw)
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(raw, toHeaders: 6) }
        // A checkpoint-rooted file would be assuming what is being derived.
        var rooted = Data()
        rooted.appendLittleEndian(CheckpointGenerator.checkpointRootedMarker)
        rooted.append(raw.dropFirst(4))
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(rooted, toHeaders: 1) }
        // A file shorter than its count claims.
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(raw.dropLast(1), toHeaders: 5) }
    }

    @Test("headers are sliced by height out of the genesis-rooted file")
    func slice() throws {
        let headers = syntheticHeaders(6)
        let raw = genesisRootedFile(headers)
        #expect(try CheckpointGenerator.headers(in: raw, from: 2, throughInclusive: 4) == Array(headers[2 ... 4]))
        #expect(try CheckpointGenerator.headers(in: raw, from: 5, throughInclusive: 5) == [headers[5]])
        #expect(throws: GenerateError.self) { try CheckpointGenerator.headers(in: raw, from: 4, throughInclusive: 6) }
        #expect(throws: GenerateError.self) { try CheckpointGenerator.headers(in: raw, from: 4, throughInclusive: 3) }
    }

    @Test("heights are spelled the way the source spells them")
    func grouped() {
        #expect(CheckpointGenerator.grouped(900_000, separator: "_") == "900_000")
        #expect(CheckpointGenerator.grouped(1_234_567, separator: ",") == "1,234,567")
        #expect(CheckpointGenerator.grouped(100, separator: "_") == "100")
        #expect(CheckpointGenerator.grouped(0, separator: "_") == "0")
    }

    @Test("the literal for the shipped checkpoint is the source, line for line")
    func literalMatchesSource() throws {
        let shipped = try #require(NetworkParams.mainnet.checkpoint)
        let literal = CheckpointGenerator.literal(height: shipped.height,
                                                  header: try BlockHeader.decode(shipped.header),
                                                  work: shipped.chainwork)
        let source = try String(
            contentsOf: WinnowGenerate.packageRoot.appending(path: "Sources/BitcoinP2P/Protocol/NetworkParams.swift"),
            encoding: .utf8)
        func trimmed(_ text: String) -> [String] {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let wanted = trimmed(literal)
        let lines = trimmed(source)
        let start = try #require(lines.firstIndex(of: wanted[0]))
        try #require(start + wanted.count <= lines.count)
        // Contiguous, so the paste is a pure replacement.
        #expect(Array(lines[start ..< start + wanted.count]) == wanted)
    }

    @Test("vector lines are 160 lowercase hex characters that decode back to the header")
    func vector() throws {
        let real = try BlockHeader.decode(Self.block900_001)
        let headers = syntheticHeaders(3) + [real]
        let text = CheckpointGenerator.vectorText(headers)
        let lines = text.split(separator: "\n")
        #expect(text.hasSuffix("\n"))
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { line in
            line.count == 160 && line.allSatisfy { character in character.isHexDigit && !character.isUppercase }
        })
        let decoded = try lines.map { line -> BlockHeader in
            let bytes = try #require(Data(hex: String(line)))
            return try BlockHeader.decode(bytes)
        }
        #expect(decoded == headers)
    }

    @Test("the derived checkpoint replaces only the checkpoint in the parameters")
    func replacedCheckpoint() throws {
        let params = NetworkParams.mainnet
        let shipped = try #require(params.checkpoint)
        let replacement = NetworkParams.Checkpoint(height: 1, header: shipped.header, chainwork: shipped.chainwork)
        let swapped = CheckpointGenerator.parameters(params, with: replacement)
        #expect(swapped.checkpoint == replacement)
        #expect(swapped.magic == params.magic)
        #expect(swapped.dnsSeeds == params.dnsSeeds)
        #expect(swapped.fallbackPeers == params.fallbackPeers)
        #expect(swapped.genesisHash == params.genesisHash)
    }

    @Test("the shipped constant is compared only at its own height")
    func compareWithShipped() throws {
        let shipped = try #require(NetworkParams.mainnet.checkpoint)
        try CheckpointGenerator.compare(shipped, shipped: shipped)
        try CheckpointGenerator.compare(shipped, shipped: nil)
        let elsewhere = NetworkParams.Checkpoint(height: shipped.height + 1, header: shipped.header,
                                                 chainwork: shipped.chainwork)
        try CheckpointGenerator.compare(elsewhere, shipped: shipped)
        let wrong = NetworkParams.Checkpoint(height: shipped.height, header: shipped.header,
                                             chainwork: Data(repeating: 0, count: 32))
        #expect(throws: GenerateError.self) { try CheckpointGenerator.compare(wrong, shipped: shipped) }
    }

    @Test("agreement holds between chains on the same tip and fails once they differ")
    func agreement() async throws {
        let params = NetworkParams.mainnet
        let shipped = try #require(params.checkpoint)
        let one = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        let other = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height])

        let next = try BlockHeader.decode(Self.block900_001)
        #expect(try await one.connect([next]).appended == 1)
        await #expect(throws: GenerateError.self) {
            try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height])
        }
        #expect(try await other.connect([next]).appended == 1)
        try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height, shipped.height + 1])
    }
}
