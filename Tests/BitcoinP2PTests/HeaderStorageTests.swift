import Foundation
import Testing
import TestSupport
@testable import BitcoinP2P

/// The persisted header file, one suite for one file format.
///
/// The layout is a fixed prefix plus fixed 80-byte records. A genesis-rooted
/// chain writes the original prefix — a bare 4-byte record count. A
/// checkpoint-rooted chain (#89) writes the marker layout instead: a 48-byte
/// prefix of marker, version, base height, base work and the count at offset
/// 44. Every case below reloads from disk, because `load` re-checks proof of
/// work and linkage on every header, so a byte in the wrong place shows up as
/// a broken chain rather than as silently wrong bytes.
///
/// Combined from `HeaderStorageAppendTests`, `HeaderStorageCorruptionTests`
/// and `HeaderStorageBoundsTests`, none of which carried a suite trait. The
/// three private chain builders those files each carried are now the one
/// `headers(after:count:time:)` and the one `persistedChain()` below.
@Suite("Header storage")
struct HeaderStorageTests {

    // MARK: - Fixtures

    /// `count` headers building on `previous`, at trivial difficulty.
    static func headers(after previous: Data, count: Int, time: UInt32 = 1_600_000_000) -> [BlockHeader] {
        var result: [BlockHeader] = []
        var parent = previous
        for index in 0 ..< count {
            let header = minedHeader(previousHash: parent,
                                     merkleRoot: Data(repeating: UInt8(index % 251 + 1), count: 32),
                                     time: time + UInt32(index) * 600)
            result.append(header)
            parent = header.hash
        }
        return result
    }

    /// Writes a real four-header chain and returns its file: the one
    /// persisted-chain builder for this suite, mining through the builder
    /// above rather than repeating the loop.
    static func persistedChain() async throws -> (url: URL, params: NetworkParams, bytes: Data) {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        _ = try await chain.connect(headers(after: synthetic.blocks[0].hash, count: 4))
        let bytes = try Data(contentsOf: url)
        return (url, synthetic.params, bytes)
    }

    /// A checkpoint-rooted chain and its params, so the marker layout can be
    /// exercised without a real 77 MB mainnet header file.
    ///
    /// The checkpoint is a header from a synthetic chain, carrying the work of
    /// everything up to it — which is what `NetworkParams.Checkpoint` means and
    /// what `load` puts back when it reads the prefix.
    static func checkpointRooted() throws -> (params: NetworkParams, tipHash: Data) {
        let synthetic = makeSyntheticChain(length: 3, watchHeight: 2)
        let genesisParams = synthetic.params
        let checkpointHeight: UInt32 = 3
        let header = synthetic.blocks[Int(checkpointHeight)].header

        var work = UInt256()
        for height in 0 ... checkpointHeight {
            work = work + (try HeaderChain.checkedWork(for: synthetic.blocks[Int(height)].header,
                                                       params: genesisParams, height: height))
        }
        let params = NetworkParams(
            network: .signet, magic: genesisParams.magic, defaultPort: genesisParams.defaultPort,
            genesisTime: genesisParams.genesisTime, genesisBits: genesisParams.genesisBits,
            genesisNonce: genesisParams.genesisNonce,
            genesisMerkleRoot: genesisParams.genesisMerkleRoot,
            genesisHash: genesisParams.genesisHash, powLimit: genesisParams.powLimit,
            dnsSeeds: [],
            checkpoint: NetworkParams.Checkpoint(height: checkpointHeight,
                                                 header: header.serialized,
                                                 chainwork: work.bigEndianData))
        return (params, header.hash)
    }

    static func write(_ bytes: Data) throws -> URL {
        let url = tempFileURL("headers.dat")
        try bytes.write(to: url)
        return url
    }

    /// Loads a byte image that is expected to succeed, and returns the chain.
    static func load(_ bytes: Data, params: NetworkParams) throws -> HeaderChain {
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        return try HeaderChain(params: params, storageURL: url)
    }

    /// Loads a byte image and returns the error, or nil if it loaded.
    static func loadError(_ bytes: Data, params: NetworkParams) throws -> HeaderChainError? {
        let url = try write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try HeaderChain(params: params, storageURL: url)
            return nil
        } catch let error as HeaderChainError {
            return error
        }
    }

    /// Creates a file that *reports* a huge size without occupying the disk,
    /// so the size guard can be exercised without writing 256 MB.
    static func sparseFile(bytes: Int64) throws -> URL {
        let url = tempFileURL("headers.dat")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    // MARK: - Header storage append
    //
    // Header persistence writes only the new headers (#83).
    //
    // Rewriting the whole file per batch is what made mainnet header sync slow
    // down as it ran — 963,000 headers is 77 MB, re-serialised and re-written
    // on each of ~460 batches. An append is a write at a known offset followed
    // by an updated count.
    //
    // What these pin is the part an append can get wrong and a single-batch
    // test cannot see: the second write has to land where the first one ended,
    // and the count has to admit exactly the records that are there.

    /// The production path, and the one every other test here misses.
    ///
    /// Since #89 a mainnet wallet starts from the checkpoint, which writes the
    /// *marker* layout: a 48-byte prefix with the count at offset 44, not the
    /// 4-byte prefix with the count at 0 that a genesis-rooted chain uses. The
    /// second batch of a mainnet first launch is therefore the first time an
    /// append ever runs against that layout — in production, and until now
    /// with no test behind it.
    ///
    /// Getting the offsets the wrong way round would be loud rather than
    /// silent: the next load refuses the file and the wallet resyncs. But it
    /// would corrupt the header file of every mainnet user on their second
    /// batch, and swapping the two layouts' offsets would break no test.
    @Test("appending to a checkpoint-rooted file uses the marker layout's offsets")
    func appendToCheckpointRootedFile() async throws {
        let (params, checkpointTip) = try Self.checkpointRooted()
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(await chain.startHeight == 3, "fixture precondition: the marker layout")

        let first = Self.headers(after: checkpointTip, count: 3, time: 1_900_000_000)
        _ = try await chain.connect(first)
        let second = Self.headers(after: first[first.count - 1].hash, count: 4, time: 1_900_100_000)
        _ = try await chain.connect(second)
        #expect(await chain.height == 10)

        let reloaded = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(await reloaded.height == 10)
        #expect(await reloaded.tipHash == chain.tipHash)
        #expect(await reloaded.startHeight == 3)

        // 48-byte prefix, not 4 — the whole point of this case.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 48 + 8 * BlockHeader.serializedSize)
    }

    /// The case a single-batch test cannot reach: the second append must start
    /// where the first one finished. An offset that is wrong by even one record
    /// reloads as a broken chain.
    @Test("two appends in a row reload as one chain")
    func appendAfterAppendReloads() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        let first = Self.headers(after: synthetic.blocks[0].hash, count: 3)
        _ = try await chain.connect(first)
        let second = Self.headers(after: first[first.count - 1].hash, count: 4, time: 1_600_100_000)
        _ = try await chain.connect(second)
        #expect(await chain.height == 7)

        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == 7)
        #expect(await reloaded.tipHash == chain.tipHash)

        // And the file is exactly as long as its count implies — an append
        // that left a stale tail behind would still reload, so length is the
        // only thing that catches it.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 4 + 8 * BlockHeader.serializedSize)
    }

    /// A reorg replaces headers rather than adding them, so it takes the full
    /// rewrite. What matters here is the append that comes *after*: the writer
    /// has to know the file shrank, or it writes the next batch past the end.
    @Test("an append after a reorg lands at the new end of the file")
    func appendAfterReorgReloads() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        let original = Self.headers(after: synthetic.blocks[0].hash, count: 4)
        _ = try await chain.connect(original)
        #expect(await chain.height == 4)

        // Replace the last three with a longer branch off height 1.
        let replacement = Self.headers(after: original[0].hash, count: 5, time: 1_700_000_000)
        _ = try await chain.connect(replacement)
        #expect(await chain.height == 6)

        // Now append onto the reorganised chain.
        let continuation = Self.headers(after: replacement[replacement.count - 1].hash,
                                        count: 2, time: 1_800_000_000)
        _ = try await chain.connect(continuation)
        #expect(await chain.height == 8)

        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == 8)
        #expect(await reloaded.tipHash == chain.tipHash)

        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 4 + 9 * BlockHeader.serializedSize)
    }

    /// A chain reopened from disk has to know how much of it is already
    /// written, or the first append after a restart writes at the wrong place.
    @Test("an append after reopening the file continues the chain")
    func appendAfterReopenReloads() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = Self.headers(after: synthetic.blocks[0].hash, count: 3)
        do {
            let chain = try HeaderChain(params: synthetic.params, storageURL: url)
            _ = try await chain.connect(first)
        }

        let reopened = try HeaderChain(params: synthetic.params, storageURL: url)
        let second = Self.headers(after: first[first.count - 1].hash, count: 3, time: 1_600_200_000)
        _ = try await reopened.connect(second)
        #expect(await reopened.height == 6)

        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == 6)
        #expect(await reloaded.tipHash == reopened.tipHash)
    }

    /// A failed write leaves the chain in memory ahead of the chain on disk,
    /// and the next append must notice rather than write at an offset the file
    /// never reached. This is the only way that divergence occurs, so it is
    /// what the persisted-count check is actually for.
    @Test("an append after a failed write falls back to rewriting the file")
    func appendAfterFailedWriteRecovers() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }

        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        let first = Self.headers(after: synthetic.blocks[0].hash, count: 3)
        _ = try await chain.connect(first)

        // Make the file unwritable, so the next append fails after the headers
        // are already in memory.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let second = Self.headers(after: first[first.count - 1].hash, count: 2, time: 1_600_400_000)
        var writeFailed = false
        do {
            _ = try await chain.connect(second)
        } catch {
            writeFailed = true
        }
        #expect(writeFailed, "fixture precondition: the append had to fail")
        #expect(await chain.height == 5, "the headers are accepted in memory even when the write fails")

        // Disk is now three headers behind memory. The next append must not
        // write at the offset memory implies.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let third = Self.headers(after: second[second.count - 1].hash, count: 2, time: 1_600_500_000)
        _ = try await chain.connect(third)

        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == 7)
        #expect(await reloaded.tipHash == chain.tipHash)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 4 + 8 * BlockHeader.serializedSize)
    }

    /// The interrupted-append shape, produced deliberately: headers on disk
    /// that the count does not admit yet. Reopening must read the committed
    /// chain, and the next append must overwrite the orphaned tail rather than
    /// build on top of it.
    @Test("an interrupted append is overwritten by the next one")
    func interruptedAppendIsOverwritten() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let committed = Self.headers(after: synthetic.blocks[0].hash, count: 3)
        do {
            let chain = try HeaderChain(params: synthetic.params, storageURL: url)
            _ = try await chain.connect(committed)
        }

        // Simulate the crash window: payload written, count not yet updated.
        // The tail is deliberately LONGER than the append that follows it —
        // three orphaned records against one new header — because a shorter
        // tail would be overwritten by the next write regardless, and the
        // truncation this pins would go untested.
        var torn = try Data(contentsOf: url)
        torn.append(Data(repeating: 0xEE, count: 3 * BlockHeader.serializedSize))
        try torn.write(to: url)

        let reopened = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reopened.height == 3, "the uncommitted tail must not count as a header")

        let next = Self.headers(after: committed[committed.count - 1].hash, count: 1, time: 1_600_300_000)
        _ = try await reopened.connect(next)

        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == 4)
        #expect(await reloaded.tipHash == reopened.tipHash)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 4 + 5 * BlockHeader.serializedSize,
                "the orphaned tail must be truncated away, not left past the new end")
    }

    /// Not an assertion about wall-clock time, which would be flaky. It pins
    /// the *shape* of the cost: the bytes written across a sync must grow with
    /// the number of headers, not with their square. A whole-file rewrite per
    /// batch writes sum(n) records; an append writes n.
    @Test("total bytes written grows linearly, not quadratically, across batches")
    func writeVolumeIsLinear() async throws {
        let synthetic = makeSyntheticChain(length: 1, watchHeight: 6)
        let url = tempFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        var parent = synthetic.blocks[0].hash
        let batches = 20
        let perBatch = 10
        for batch in 0 ..< batches {
            let batchHeaders = Self.headers(after: parent, count: perBatch,
                                            time: 1_600_000_000 + UInt32(batch) * 100_000)
            _ = try await chain.connect(batchHeaders)
            parent = batchHeaders[batchHeaders.count - 1].hash
        }

        let total = batches * perBatch
        #expect(await chain.height == UInt32(total))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 4 + (total + 1) * BlockHeader.serializedSize)

        // A rewrite-per-batch writer would have written ~sum(batch*perBatch)
        // records — an order more than the file it ends up with. The append
        // writer touches each record once, so the file it produces and the
        // volume it wrote are the same order.
        let reloaded = try HeaderChain(params: synthetic.params, storageURL: url)
        #expect(await reloaded.height == UInt32(total))
        #expect(await reloaded.tipHash == chain.tipHash)
    }

    // MARK: - Header storage corruption
    //
    // A damaged header file must never load as a chain (epic #100, invariant
    // S5).
    //
    // Header storage is read during startup and everything downstream trusts
    // it: filter sync pins against it, and the wallet's confirmations are
    // heights in it. A file that loaded partially, or loaded a fabricated
    // chain, would not announce itself — the wallet would simply be syncing
    // against something that was never mined.
    //
    // So each damage mode is checked for a specific refusal rather than "some
    // error", because the modes fail for different reasons and a single broad
    // assertion would pass even if one of them stopped being checked.

    /// Positive control: the intact file loads. Every refusal below is only
    /// meaningful against this.
    @Test("an intact header file loads")
    func intactFileLoads() async throws {
        let (url, params, _) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        let reloaded = try HeaderChain(params: params, storageURL: url)
        #expect(await reloaded.height == 4)
    }

    /// Bytes lost from the end: the declared count no longer matches.
    @Test("a truncated file is refused")
    func truncatedFileRefused() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = try Self.loadError(bytes.dropLast(40), params: params)
        guard case let .storageCorrupt(reason)? = error, reason.contains("bad length") else {
            Issue.record("truncation gave \(String(describing: error)) rather than a length refusal")
            return
        }
    }

    /// Trailing bytes were refused until headers began being appended (#83).
    /// They are now the signature of a crash between writing the headers and
    /// writing the count that admits them, which is a recoverable state rather
    /// than damage — refusing it would turn any crash during header sync into
    /// a corrupt-file error and a full resync.
    ///
    /// The tail is ignored, not trusted: the count decides how many records
    /// are read, so nothing past it is ever decoded. Padding was never the
    /// barrier anyway — anyone able to append bytes can adjust the count to
    /// match. The barrier is the per-header proof-of-work and linkage checks,
    /// which the tests below still pin.
    @Test("a file with trailing bytes loads, ignoring the tail")
    func trailingBytesIgnored() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }

        let intact = try Self.load(bytes, params: params)
        let padded = try Self.load(bytes + Data(repeating: 0, count: 80), params: params)
        #expect(await padded.height == intact.height)
        #expect(await padded.tipHash == intact.tipHash)
    }

    /// A partial record is the same case mid-write: fewer than 80 bytes of the
    /// next header made it to disk before the crash.
    @Test("a partially written trailing header is ignored")
    func partialTrailingHeaderIgnored() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }

        let intact = try Self.load(bytes, params: params)
        let torn = try Self.load(bytes + Data(repeating: 0xAB, count: 37), params: params)
        #expect(await torn.height == intact.height)
        #expect(await torn.tipHash == intact.tipHash)
    }

    /// The other direction stays a refusal, and this is the asymmetry that
    /// makes the relaxation above safe: a count claiming headers that are not
    /// on disk is real damage, and the writer never produces it because the
    /// headers are written first.
    @Test("a count claiming more headers than the file holds is refused")
    func countBeyondFileRefused() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }

        // Genesis layout: the count is the first four bytes.
        var inflated = bytes
        inflated.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: UInt32(9_999).littleEndian) { Data($0) })
        let error = try Self.loadError(inflated, params: params)
        guard case let .storageCorrupt(reason)? = error, reason.contains("bad length") else {
            Issue.record("an inflated count gave \(String(describing: error)) rather than a length refusal")
            return
        }
    }

    /// A file written by a future format must not be read under this one's
    /// assumptions.
    ///
    /// Built by hand: a genesis-rooted chain writes the original layout (a
    /// bare count), so the versioned layout only appears for checkpoint-rooted
    /// files and cannot be produced from a synthetic chain.
    @Test("an unknown format version is refused")
    func unknownFormatVersionRefused() async throws {
        let (url, params, _) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }

        var damaged = Data()
        damaged.appendUInt32(0xFFFF_FFFF) // format marker
        damaged.appendUInt32(99) // a version this build does not know
        damaged.appendUInt32(1) // base height
        damaged.append(Data(repeating: 0, count: 32)) // base work
        damaged.appendUInt32(0) // count
        let expectedPrefix = 48 // marker + version + baseHeight + work + count
        #expect(damaged.count == expectedPrefix)

        let error = try Self.loadError(damaged, params: params)
        guard case let .storageCorrupt(reason)? = error, reason.contains("version") else {
            Issue.record("bad version gave \(String(describing: error))")
            return
        }
    }

    /// A prefix cut short must not be read as a zero-length chain.
    @Test("a truncated prefix is refused")
    func truncatedPrefixRefused() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        let error = try Self.loadError(bytes.prefix(10), params: params)
        guard case .storageCorrupt? = error else {
            Issue.record("a 10-byte file gave \(String(describing: error))")
            return
        }
    }

    /// Headers reordered in place keep the file's length and every individual
    /// header valid, so only the linkage check catches it. This is the damage
    /// mode a length or checksum test would miss.
    @Test("headers reordered in place are refused")
    func brokenLinkageRefused() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        // A genesis-rooted file is a 4-byte count followed by headers, and
        // header 0 is genesis. Swapping the two *after* it leaves the genesis
        // check satisfied so that only the linkage check can object.
        let prefix = 4
        let size = BlockHeader.serializedSize
        var damaged = bytes
        let a = (prefix + size) ..< (prefix + 2 * size)
        let b = (prefix + 2 * size) ..< (prefix + 3 * size)
        let first = Data(damaged[a])
        let second = Data(damaged[b])
        damaged.replaceSubrange(a, with: second)
        damaged.replaceSubrange(b, with: first)

        let error = try Self.loadError(damaged, params: params)
        guard case let .storageCorrupt(reason)? = error, reason.contains("linkage") else {
            Issue.record("reordering gave \(String(describing: error)) rather than a linkage refusal")
            return
        }
    }

    /// A single flipped byte inside a header breaks its hash, and therefore
    /// the chain that follows it.
    @Test("a flipped byte inside a header is refused")
    func flippedByteRefused() async throws {
        let (url, params, bytes) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        let prefix = 4
        var damaged = bytes
        damaged[prefix + 4] ^= 0xFF // inside the first header's previousHash
        #expect(try Self.loadError(damaged, params: params) != nil,
                "a corrupted header must not load")
    }

    /// An empty file is damage, not an empty chain.
    @Test("an empty file is refused")
    func emptyFileRefused() async throws {
        let (url, params, _) = try await Self.persistedChain()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try Self.loadError(Data(), params: params) != nil)
    }

    // MARK: - Header storage bounds
    //
    // Bounds on the persisted header file (epic #100, invariant S10).
    //
    // The compact-filter progress file already refuses to be read past a
    // ceiling. The header file did not, and it is read during startup:
    // `Data(contentsOf:)` on an arbitrarily large file exhausts memory before
    // any of the fail-closed corruption handling downstream can run. That is
    // the same shape as the descriptor crash in `SEC-010` — a hostile or
    // damaged store taking the app down at launch rather than being rejected
    // by it.
    //
    // Mainnet headers are 80 bytes each and grow by roughly 4 MB a year, so a
    // real chain is far below the ceiling and these refusals cannot affect
    // one. An ordinary persisted chain round-tripping through the same guard
    // is `HeaderChainTests.persistence`.

    @Test("a header file above the ceiling is refused before it is read")
    func oversizedHeaderFileRefused() throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 2)
        let url = try Self.sparseFile(bytes: Int64(HeaderChain.maximumHeaderFileBytes) + 1)
        defer { try? FileManager.default.removeItem(at: url) }

        // Confirm the fixture really does present an oversized file.
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(size?.int64Value ?? 0 > Int64(HeaderChain.maximumHeaderFileBytes))

        do {
            _ = try HeaderChain(params: chain.params, storageURL: url)
            Issue.record("an oversized header file was accepted")
        } catch let error as HeaderChainError {
            guard case let .storageCorrupt(message) = error, message.contains("above the") else {
                Issue.record("rejected as \(error) rather than an over-limit storageCorrupt")
                return
            }
        }
    }

    /// Positive control: a file just under the ceiling is not rejected for
    /// being too large. It is still refused — a sparse file is not a valid
    /// header chain — but as a corrupt chain rather than an oversized one, so
    /// the size guard is not simply rejecting everything.
    @Test("a file under the ceiling is not rejected for its size")
    func underLimitNotRejectedForSize() throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 2)
        let url = try Self.sparseFile(bytes: 4_096)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try HeaderChain(params: chain.params, storageURL: url)
        } catch let error as HeaderChainError {
            if case let .storageCorrupt(message) = error {
                #expect(!message.contains("above the"),
                        "a small file must not be refused for its size")
            }
        }
    }
}
