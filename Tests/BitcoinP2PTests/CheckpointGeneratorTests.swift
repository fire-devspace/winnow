import Foundation
import Testing

@testable import BitcoinP2P

/// Regenerates the shipped mainnet checkpoint from a header file this code
/// produced by syncing from genesis, and checks the constant against it (#89).
///
/// The point of the checkpoint is that nobody has to take it on faith. So it is
/// not derived by a separate parser that could agree with the constant while
/// both are wrong — the header file is loaded through `HeaderChain` itself,
/// which proof-of-work-checks every header and rejects a broken chain. What the
/// app would compute is what gets compared.
///
/// To run it:
///
///     WINNOW_HEADERS_BIN=~/…/mainnet/headers.bin \
///       swift test --filter CheckpointGenerator
///
/// Any genesis-validated mainnet `headers.bin` past height 900,000 works,
/// including one from a simulator container. Without the variable the suite
/// skips, so CI stays green without shipping a 77 MB fixture.
@Suite("CheckpointGenerator",
       .enabled(if: ProcessInfo.processInfo.environment["WINNOW_HEADERS_BIN"] != nil))
struct CheckpointGeneratorTests {
    @Test("the shipped constant is what a genesis-validated chain computes")
    func regenerate() async throws {
        let params = NetworkParams.params(for: .mainnet)
        let expected = try #require(params.checkpoint)
        let path = try #require(ProcessInfo.processInfo.environment["WINNOW_HEADERS_BIN"])
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let raw = try Data(contentsOf: source)

        // Legacy layout: count || count × 80 bytes. A checkpoint-rooted file
        // cannot be a source here — it would be assuming what we are deriving.
        var reader = ByteReader(raw)
        let count = try reader.readUInt32()
        #expect(count != 0xFFFF_FFFF,
                "source file is checkpoint-rooted; the checkpoint must come from a genesis sync")
        let wanted = expected.height + 1
        #expect(count >= wanted, "source has \(count) headers, need \(wanted)")

        // Truncate to the checkpoint height and hand the result to the real
        // loader. It re-validates linkage and proof of work on every header.
        var truncated = Data()
        truncated.appendUInt32(wanted)
        truncated.append(raw[4 ..< (4 + Int(wanted) * BlockHeader.serializedSize)])
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "winnow-checkpoint-\(wanted).bin")
        try truncated.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }

        let chain = try HeaderChain(params: params, storageURL: temp)
        let height = await chain.height
        let tip = await chain.tip
        let work = await chain.tipWork

        #expect(height == expected.height)
        #expect(tip.serialized == expected.header)
        #expect(work == expected.chainwork)
        #expect(await chain.startHeight == 0, "derived from a genesis-rooted chain")

        // Emit it in source form, so regenerating at a new height is a copy out
        // of the test log rather than a hand-assembled constant.
        let bytes = tip.serialized.map { String(format: "%02x", $0) }.joined()
        print("""

        // Block \(height) hash, display order:
        //   \(tip.hash.displayHex)
        checkpoint: Checkpoint(
            height: \(height),
            header: Data(hex:
                "\(bytes.prefix(72))"
                + "\(bytes.dropFirst(72).prefix(64))"
                + "\(bytes.dropFirst(136))")!,
            chainwork: Data(hex:
                "\(work.map { String(format: "%02x", $0) }.joined())")!
        )

        """)
    }
}
