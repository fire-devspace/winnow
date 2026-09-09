import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// HeaderChain by subject: consensus and fork choice, the shipped
/// checkpoints, starting somewhere other than block 0 and the policy that
/// chooses where, replayed headers, and reorg visibility.
///
/// Combined from `HeaderChainTests` (which already held four suites in one
/// file), `HeaderReplayTests` and `ReorgVisibilityTests`. None of those suites
/// carried a trait, so they are sections of this one suite rather than nested
/// suites; every test keeps its display name and its source order.
@Suite("HeaderChain")
struct HeaderChainTests {
    // MARK: - HeaderChain
    //
    // PoW-checked connect, fork choice, locator, persistence — over a
    // synthetic mined chain (bits 0x207fffff, so PoW is real but trivial).

    @Test("connects valid headers and tracks work")
    func connect() async throws {
        let chain = makeSyntheticChain(length: 5, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        let appended = try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        #expect(appended.appended == 5)
        #expect(await headerChain.height == 5)
        #expect(await headerChain.tipHash == chain.blocks[5].hash)
        #expect(await headerChain.blockHash(at: 0) == chain.blocks[0].hash)

        // Work doubles from height 2 to height 4 (constant bits).
        let work4 = await headerChain.tipWork
        #expect(!work4.isEmpty)
    }

    @Test("rejects a header that does not link to the chain")
    func rejectsUnlinked() async throws {
        let chain = makeSyntheticChain(length: 3, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        let orphan = minedHeader(previousHash: Data(repeating: 0x99, count: 32),
                                 merkleRoot: Data(repeating: 0, count: 32), time: 1_600_100_000)
        await #expect(throws: HeaderChainError.doesNotConnect) {
            try await headerChain.connect([orphan])
        }
    }

    @Test("rejects headers failing proof of work")
    func rejectsBadPoW() async throws {
        let chain = makeSyntheticChain(length: 2, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        // Link to genesis but with mainnet-hard bits and an unmined nonce.
        let bad = BlockHeader(version: 1, previousHash: chain.blocks[0].hash,
                              merkleRoot: Data(repeating: 0, count: 32),
                              time: 1_600_000_600, bits: 0x1D00_FFFF, nonce: 0)
        await #expect(throws: HeaderChainError.self) { try await headerChain.connect([bad]) }
    }

    @Test("rejects targets above powLimit")
    func rejectsAbovePowLimit() async throws {
        let chain = makeSyntheticChain(length: 2, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        // bits 0x2100ffff: target = 0xffff * 256^30 > powLimit (0x207fffff-based).
        let tooEasy = BlockHeader(version: 1, previousHash: chain.blocks[0].hash,
                                  merkleRoot: Data(repeating: 0, count: 32),
                                  time: 1_600_000_600, bits: 0x2100_FFFF, nonce: 0)
        await #expect(throws: HeaderChainError.targetAbovePowLimit(height: 1)) {
            try await headerChain.connect([tooEasy])
        }
    }

    @Test("refuses a difficulty change inside a retarget period")
    func rejectsBitsChangeMidPeriod() async throws {
        let chain = makeSyntheticChain(length: 2, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        let tip = chain.blocks[2].header

        // One notch harder than the chain's 0x207fffff: still under powLimit
        // and mined for real, so only the schedule rule can refuse it.
        let changed = Self.mined(onto: tip, bits: 0x207F_FFFE, tag: 0xD1,
                                 params: chain.params, height: 3)
        await #expect(throws: HeaderChainError.unexpectedDifficulty(height: 3)) {
            try await headerChain.connect([changed])
        }
        #expect(await headerChain.height == 2)
        #expect(await headerChain.tipHash == tip.hash)

        // Positive control: the same header with the chain's bits connects.
        let unchanged = Self.mined(onto: tip, bits: tip.bits, tag: 0xD1,
                                   params: chain.params, height: 3)
        #expect(try await headerChain.connect([unchanged]).appended == 1)
        #expect(await headerChain.height == 3)
        #expect(await headerChain.tipHash == unchanged.hash)
    }

    @Test("a replacement branch is held to the same rule")
    func rejectsBitsChangeInBranch() async throws {
        let chain = makeSyntheticChain(length: 2, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        let tipBefore = await headerChain.tipHash

        // Forks at genesis and would carry more work than the chain, but its
        // second header changes bits at height 2.
        let genesis = chain.blocks[0].header
        let first = Self.mined(onto: genesis, bits: genesis.bits, tag: 0xD2,
                               params: chain.params, height: 1)
        let second = Self.mined(onto: first, bits: 0x207F_FFFE, tag: 0xD2,
                                params: chain.params, height: 2)
        let third = Self.mined(onto: second, bits: 0x207F_FFFE, tag: 0xD2,
                               params: chain.params, height: 3)
        await #expect(throws: HeaderChainError.unexpectedDifficulty(height: 2)) {
            try await headerChain.connect([first, second, third])
        }
        #expect(await headerChain.height == 2)
        #expect(await headerChain.tipHash == tipBefore)
    }

    @Test("bits may change at a period boundary; an unknown parent is not judged")
    func stableBitsRuleEdges() throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let genesis = chain.blocks[0].header
        let harder = BlockHeader(version: 1, previousHash: genesis.hash,
                                 merkleRoot: Data(repeating: 0xD3, count: 32),
                                 time: genesis.time + 600, bits: 0x207F_FFFE, nonce: 0)
        let interval = HeaderChain.difficultyAdjustmentInterval
        #expect(throws: HeaderChainError.unexpectedDifficulty(height: 1)) {
            try HeaderChain.requireStableBits(harder, previous: genesis, height: 1)
        }
        #expect(throws: HeaderChainError.unexpectedDifficulty(height: interval + 1)) {
            try HeaderChain.requireStableBits(harder, previous: genesis, height: interval + 1)
        }
        // The first block of a period is where the schedule allows a change.
        try HeaderChain.requireStableBits(harder, previous: genesis, height: interval)
        try HeaderChain.requireStableBits(harder, previous: genesis, height: interval * 3)
        // Unchanged bits pass anywhere inside the period.
        try HeaderChain.requireStableBits(genesis, previous: genesis, height: 1)
        // A parent below the chain's base is unknown: nothing to compare against.
        try HeaderChain.requireStableBits(harder, previous: nil, height: 1)
    }

    @Test("a longer branch replaces; a shorter one is refused")
    func forkChoice() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let genesis = chain.blocks[0]
        let headerChain = try HeaderChain(params: chain.params)

        func branch(count: Int, tag: UInt8, fromTime time: UInt32) -> [BlockHeader] {
            var headers: [BlockHeader] = []
            var previous = genesis.hash
            for i in 0 ..< count {
                let header = minedHeader(previousHash: previous,
                                         merkleRoot: Data(repeating: tag, count: 32),
                                         time: time + UInt32(i) * 600)
                headers.append(header)
                previous = header.hash
            }
            return headers
        }

        let branchA = branch(count: 3, tag: 0xAA, fromTime: 1_600_010_000)
        try await headerChain.connect(branchA)
        #expect(await headerChain.tipHash == branchA[2].hash)

        // Shorter competing branch (less work) must not replace the tip.
        let shorter = branch(count: 2, tag: 0xBB, fromTime: 1_600_020_000)
        await #expect(throws: HeaderChainError.reorgWithoutMoreWork) {
            try await headerChain.connect(shorter)
        }
        #expect(await headerChain.tipHash == branchA[2].hash)

        // Longer branch (more work) reorganizes the chain.
        let longer = branch(count: 5, tag: 0xCC, fromTime: 1_600_030_000)
        try await headerChain.connect(longer)
        #expect(await headerChain.height == 5)
        #expect(await headerChain.tipHash == longer[4].hash)
    }

    @Test("headers the chain already holds are skipped, not read as a weaker branch")
    func replayedHeadersAreNotABranch() async throws {
        // The storefront capture found this on the signet fixture: a block
        // announcement and the reply to the getheaders it prompted both
        // carry the same header, the second copy waited in the connection's
        // backlog, and the next sync took it as the answer. Read as a branch
        // forking one below the tip with no more work, the peer was
        // condemned for the session — the only peer, so the app went dark.
        let chain = makeSyntheticChain(length: 6, watchHeight: 8)
        let headers = chain.blocks.dropFirst().map(\.header)
        let headerChain = try HeaderChain(params: chain.params)
        try await headerChain.connect(Array(headers[0 ..< 4]))
        #expect(await headerChain.height == 4)

        // The tip again, alone: an announcement replayed.
        let replayedTip = try await headerChain.connect([headers[3]])
        #expect(replayedTip.appended == 0)
        #expect(replayedTip.forkHeight == nil)
        #expect(await headerChain.height == 4)

        // A header below the tip, alone: a stale reply.
        let stale = try await headerChain.connect([headers[2]])
        #expect(stale.appended == 0)
        #expect(await headerChain.tipHash == headers[3].hash)

        // A reply that overlaps the tip appends only what is new.
        let overlapping = try await headerChain.connect(Array(headers[2 ..< 6]))
        #expect(overlapping.appended == 2)
        #expect(overlapping.forkHeight == nil)
        #expect(await headerChain.height == 6)
        #expect(await headerChain.tipHash == headers[5].hash)

        // A genuinely competing branch is still judged on work.
        let rival = minedHeader(previousHash: headers[4].hash,
                                merkleRoot: Data(repeating: 0xEE, count: 32), time: 1_600_090_000)
        await #expect(throws: HeaderChainError.reorgWithoutMoreWork) {
            try await headerChain.connect([rival])
        }
    }

    @Test("block locator: tip first, exponential steps, genesis last")
    func locator() async throws {
        let chain = makeSyntheticChain(length: 20, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        let locator = await headerChain.blockLocator()
        #expect(locator.first == chain.blocks[20].hash)
        #expect(locator.last == chain.blocks[0].hash)
        // 10 single steps then doubling: heights 20,19,…,11, then 9,7,3? — just
        // assert monotonic decrease and full inclusion of the recent window.
        for header in chain.blocks[11 ... 20] {
            #expect(locator.contains(header.hash))
        }
    }

    @Test("persists and reloads from disk, re-validating PoW")
    func persistence() async throws {
        let chain = makeSyntheticChain(length: 4, watchHeight: 6)
        let file = tempFileURL("headers.dat")
        let headerChain = try HeaderChain(params: chain.params, storageURL: file)
        try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        let reloaded = try HeaderChain(params: chain.params, storageURL: file)
        #expect(await reloaded.height == 4)
        #expect(await reloaded.tipHash == chain.blocks[4].hash)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// A build that cannot interpret a checkpoint-rooted file must say so
    /// rather than read it as genesis-rooted — that would silently shift every
    /// height in the chain, and nothing downstream would notice (#89).
    @Test("a checkpoint-rooted header file is refused, not misread")
    func checkpointFileRefused() async throws {
        let chain = makeSyntheticChain(length: 2, watchHeight: 6)
        let file = tempFileURL("headers.dat")

        var data = Data()
        data.appendUInt32(0xFFFF_FFFF)          // format marker
        data.appendUInt32(1)                    // version
        data.appendUInt32(500_000)              // base height
        data.append(Data(repeating: 0, count: 32)) // base work
        data.appendUInt32(UInt32(chain.blocks.count))
        for block in chain.blocks { data.append(block.header.serialized) }
        try data.write(to: file)

        #expect(throws: HeaderChainError.self) {
            _ = try HeaderChain(params: chain.params, storageURL: file)
        }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test("repeated difficulty caching still verifies every stored header hash")
    func cachedDifficultyStillChecksPoW() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let genesis = chain.blocks[0].header
        var nonce: UInt32 = 0
        var bad = BlockHeader(version: 1, previousHash: genesis.hash,
                              merkleRoot: Data(repeating: 0xA5, count: 32),
                              time: genesis.time + 600, bits: genesis.bits, nonce: nonce)
        while (try? HeaderChain.checkedWork(for: bad, params: chain.params, height: 1)) != nil {
            nonce &+= 1
            bad = BlockHeader(version: 1, previousHash: genesis.hash,
                              merkleRoot: bad.merkleRoot, time: bad.time,
                              bits: genesis.bits, nonce: nonce)
        }

        let file = tempFileURL("headers.dat")
        var stored = Data()
        stored.appendUInt32(2)
        stored.append(genesis.serialized)
        stored.append(bad.serialized)
        try stored.write(to: file)
        #expect(throws: HeaderChainError.insufficientProofOfWork(height: 1)) {
            _ = try HeaderChain(params: chain.params, storageURL: file)
        }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Mines a header onto `parent` at the given `bits`, accepted by the same
    /// check the chain applies, so a refusal in the tests above can only come
    /// from the schedule rule and never from proof of work.
    private static func mined(onto parent: BlockHeader, bits: UInt32, tag: UInt8,
                              params: NetworkParams, height: UInt32) -> BlockHeader {
        var nonce: UInt32 = 0
        while true {
            let header = BlockHeader(version: 1, previousHash: parent.hash,
                                     merkleRoot: Data(repeating: tag, count: 32),
                                     time: parent.time + 600, bits: bits, nonce: nonce)
            if (try? HeaderChain.checkedWork(for: header, params: params, height: height)) != nil {
                return header
            }
            nonce &+= 1
        }
    }

    // MARK: - Shipped checkpoints
    //
    // A shipped checkpoint is a constant someone has to trust, so it should be
    // impossible to get wrong quietly. These are the checks that can run
    // without the headers it was derived from (#89), and they run for every
    // network that ships one: a second constant earns the same scrutiny as the
    // first, and the way to give it that is a parameter, not a copy.

    /// What a shipped checkpoint claims, written out here rather than read
    /// back off the constant under test. An expectation derived from the value
    /// it is checking agrees with a typo exactly as happily as with the truth.
    struct Shipped: Sendable {
        let network: BitcoinNetwork
        let height: UInt32
        /// The block hash in display order, as the provenance comment records it.
        let displayHash: String
        /// Cumulative work through `height`, big-endian, as hex.
        let chainwork: String
        /// The serialized header of the block right after the checkpoint.
        let nextHeader: Data
        /// The 2,000 headers after the checkpoint, as `--vector-out` wrote them.
        let vector: String
    }

    /// Block 900,001, right after the shipped mainnet checkpoint.
    /// 00000000000000000001a8ff030609a6248e0f6e77f9f141aeb21e4eac4f83fc
    static let block900_001 = Data(hex:
        "00e000208a96960d6d1ca4ee4a283fd83da309b8d5d2bfed380501000000000000000000"
        + "371c9ffd63d75fb36c57d58eb842d23c0e7ec049daf16d94cc38805c346e9d52"
        + "e880426874370217973dc83b")!

    /// Block 300,001, right after the shipped signet checkpoint.
    /// 00000003782561b797667f4d0ed3fd36d2b0825f4c15205fb92d6bfaaefd9d0b
    static let block300_001 = Data(hex:
        "000000202cb001a3f1b07b44a95b4e0f4c73f8bab41de49ee88d00dee1e4023007000000"
        + "fb319148f2a3021590810415d48e3b4031a60f449850b08a5092298328c26ea6"
        + "ddb0dd69df43151d1f446912")!

    static let shippedCheckpoints: [Shipped] = [
        Shipped(network: .mainnet, height: 900_000,
                displayHash: "000000000000000000010538edbfd2d5b809a33dd83f284aeea41c6d0d96968a",
                chainwork: "0000000000000000000000000000000000000000c8bbeae4127a204b0317861c",
                nextHeader: block900_001,
                vector: "mainnet-headers-900001-902000.txt"),
        Shipped(network: .signet, height: 300_000,
                displayHash: "000000073002e4e1de008de89ee41db4baf8734c0f4e5ba9447bb0f1a301b02c",
                chainwork: "00000000000000000000000000000000000000000000000000000c88cd095e60",
                nextHeader: block300_001,
                vector: "signet-headers-300001-302000.txt"),
    ]

    private func constant(_ shipped: Shipped) throws -> NetworkParams.Checkpoint {
        guard let checkpoint = NetworkParams.params(for: shipped.network).checkpoint else {
            throw HeaderChainError.storageCorrupt("\(shipped.network.rawValue) has no checkpoint")
        }
        return checkpoint
    }

    /// The table above is the parameter list for everything below it, so a
    /// network missing from it would be a shipped constant nothing here reads.
    @Test("every network the app runs on ships a checkpoint this file checks")
    func everyNetworkIsChecked() {
        #expect(Set(Self.shippedCheckpoints.map(\.network)) == Set(BitcoinNetwork.checkpointed))
        for shipped in Self.shippedCheckpoints {
            #expect(NetworkParams.params(for: shipped.network).checkpoint?.height == shipped.height)
        }
    }

    @Test("the header is well formed and satisfies its own proof of work",
          arguments: Self.shippedCheckpoints)
    func headerIsValid(_ shipped: Shipped) throws {
        let cp = try constant(shipped)
        let header = try BlockHeader.decode(cp.header)
        #expect(cp.header.count == 80)
        #expect(cp.chainwork.count == 32)

        // The hash must clear the target the header itself claims. A typo in
        // the bytes fails here rather than 900,000 blocks later.
        let target = try #require(UInt256.target(compact: header.bits))
        #expect(UInt256(littleEndian: header.hash) <= target)
        #expect(target <= UInt256(littleEndian: NetworkParams.params(for: shipped.network).powLimit))
    }

    @Test("the hash matches the block recorded in the source comment",
          arguments: Self.shippedCheckpoints)
    func hashMatchesRecordedValue(_ shipped: Shipped) throws {
        let header = try BlockHeader.decode(try constant(shipped).header)
        // Display order is the reverse of internal order.
        let display = Data(header.hash.reversed()).map { String(format: "%02x", $0) }.joined()
        #expect(display == shipped.displayHash)
    }

    @Test("cumulative work is plausible for the height and below the total supply of work",
          arguments: Self.shippedCheckpoints)
    func chainworkSane(_ shipped: Shipped) throws {
        let cp = try constant(shipped)
        // Orientation first. `Data(hex:)` keeps byte order and
        // `Data(displayHex:)` reverses it, and a reversed 32-byte chainwork is
        // still enormous and still non-zero — so every plausibility check below
        // passes just as happily on garbage. Pin the actual bytes: leading
        // zeros at the front, and then the whole spelling, which fixes the
        // low-order byte at the end as surely as naming it did.
        #expect(cp.chainwork.prefix(20).allSatisfy { $0 == 0 })
        #expect(cp.chainwork.map { String(format: "%02x", $0) }.joined() == shipped.chainwork)

        let work = UInt256(bigEndian: cp.chainwork)
        // Non-zero, and far above the work of any single block: a checkpoint
        // whose chainwork was left at zero or copied from one header would
        // lose every fork-choice comparison against a genesis-rooted peer.
        #expect(!work.isZero)
        let header = try BlockHeader.decode(cp.header)
        let target = try #require(UInt256.target(compact: header.bits))
        let single = try #require(UInt256.blockWork(target: target))
        #expect(work > single)
        #expect(cp.height == shipped.height)
    }

    // MARK: - Checkpoint start
    //
    // Starting the chain somewhere other than block 0, end to end (#89 phase
    // 3).
    //
    // These run everywhere. The fixtures are the block after each checkpoint
    // and the 2,000 real headers that follow it, which is enough to make a
    // checkpoint-rooted chain do real proof-of-work checks at that network's
    // difficulty — across a retarget boundary — and write and reread a real
    // file. What they cannot prove is the checkpoint's chainwork: that number
    // summarises every header below it, and only `winnow-debug generate
    // checkpoint`, run against a genesis-validated header file at release
    // time, recomputes it and proves the genesis-rooted and checkpoint-rooted
    // chains agree (Tools/Generate/README.md).

    /// The 2,000 headers past `shipped`'s checkpoint, one 80-byte header per
    /// line as hex — what `winnow-debug generate checkpoint --vector-out`
    /// writes from a genesis-validated header file, and what the shipped
    /// constant was checked against.
    static func headersPastCheckpoint(_ shipped: Shipped) throws -> [BlockHeader] {
        let text = try String(decoding: Vectors.data(shipped.vector, in: .module), as: UTF8.self)
        return try text.split(separator: "\n").map { line in
            guard let bytes = Data(hex: String(line)), bytes.count == BlockHeader.serializedSize else {
                throw VectorError.malformed(String(line))
            }
            return try BlockHeader.decode(bytes)
        }
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "winnow-\(name).bin")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    @Test("a fresh checkpoint-started chain begins at the checkpoint, not at zero",
          arguments: Self.shippedCheckpoints)
    func startsAtCheckpoint(_ shipped: Shipped) async throws {
        let params = NetworkParams.params(for: shipped.network)
        let cp = try #require(params.checkpoint)
        let chain = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        #expect(await chain.startHeight == cp.height)
        #expect(await chain.height == cp.height)
        #expect(await chain.tip.serialized == cp.header)
        #expect(await chain.tipWork == cp.chainwork)
        // The tip is the block the constant names, not merely 80 bytes that parse.
        #expect(await chain.tipHash.displayHex == shipped.displayHash)
        // It genuinely does not hold what it skipped — no silent zero-filling.
        #expect(await chain.header(at: cp.height - 1) == nil)
        #expect(await chain.header(at: 0) == nil)
    }

    @Test("the default is still genesis, so existing callers are unchanged",
          arguments: Self.shippedCheckpoints)
    func defaultIsGenesis(_ shipped: Shipped) async throws {
        let chain = try HeaderChain(params: NetworkParams.params(for: shipped.network), storageURL: nil)
        #expect(await chain.startHeight == 0)
        #expect(await chain.height == 0)
    }

    /// Both public networks ship a checkpoint now, so the network that proves
    /// this rule is a synthetic one — which is the shape every custom signet
    /// and every mined test chain has, and why the field stays optional.
    @Test("a network with no checkpoint starts at genesis whatever the setting says")
    func noCheckpointIgnoresTheSetting() async throws {
        let params = makeSyntheticChain(length: 1, watchHeight: 1).params
        #expect(params.checkpoint == nil)
        let chain = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        #expect(await chain.startHeight == 0)
        #expect(await chain.tip == HeaderChain.genesisHeader(for: params))
    }

    /// A checkpoint-rooted chain holds one block and nothing below it, so the
    /// only headers it can accept are the ones that build on that block. This
    /// is the check that a wrong constant cannot be papered over by a peer
    /// serving some other branch of the same network.
    @Test("headers that do not build on the checkpoint are refused",
          arguments: Self.shippedCheckpoints)
    func refusesHeadersThatMissTheCheckpoint(_ shipped: Shipped) async throws {
        let params = NetworkParams.params(for: shipped.network)
        let cp = try constant(shipped)
        let chain = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)

        // This network's own genesis header: entirely real, and still refused,
        // because a chain rooted at the checkpoint holds nothing it links to.
        await #expect(throws: HeaderChainError.doesNotConnect) {
            try await chain.connect([HeaderChain.genesisHeader(for: params)])
        }
        // Real headers from further up the same chain, offered without the one
        // that joins them to the checkpoint.
        let vector = try Self.headersPastCheckpoint(shipped)
        await #expect(throws: HeaderChainError.doesNotConnect) {
            try await chain.connect(Array(vector[1 ... 2]))
        }
        // And the true successor connects, so the refusals above are about
        // linkage rather than a chain that refuses everything.
        #expect(try await chain.connect([vector[0]]).appended == 1)
        #expect(await chain.height == cp.height + 1)
    }

    @Test("a checkpoint-rooted chain connects real headers and reloads from its own file",
          arguments: Self.shippedCheckpoints)
    func roundTrip(_ shipped: Shipped) async throws {
        let params = NetworkParams.params(for: shipped.network)
        let cp = try #require(params.checkpoint)
        let url = tempURL("checkpoint-roundtrip-\(shipped.network.rawValue)")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        let next = try BlockHeader.decode(shipped.nextHeader)
        #expect(try await chain.connect([next]).appended == 1)
        #expect(await chain.height == cp.height + 1)
        let workAfter = await chain.tipWork

        // Reopening must land on exactly the same chain — this is the format
        // phase 1 added, now written and read by the same build.
        let reopened = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(await reopened.startHeight == cp.height)
        #expect(await reopened.height == cp.height + 1)
        #expect(await reopened.tipHash == next.hash)
        #expect(await reopened.tipWork == workAfter)
        #expect(await reopened.blockHash(at: cp.height) == (await chain.blockHash(at: cp.height)))

        // Then the 2,000 real headers past the checkpoint, the same blocks the
        // release-time agreement check connects: every one proof-of-work
        // checked at this network's difficulty, then written and read back.
        let vector = try Self.headersPastCheckpoint(shipped)
        #expect(vector.count == 2_000)
        #expect(vector.first == next)
        #expect(try BlockHeader.decode(cp.header).hash == vector.first?.previousHash)
        #expect(try await reopened.connect(Array(vector.dropFirst())).appended == vector.count - 1)
        #expect(await reopened.height == cp.height + UInt32(vector.count))
        let tipAfterVector = await reopened.tipHash
        let workAfterVector = await reopened.tipWork
        #expect(tipAfterVector == vector.last?.hash)
        #expect(workAfterVector != workAfter)

        let reloaded = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(await reloaded.startHeight == cp.height)
        #expect(await reloaded.height == cp.height + UInt32(vector.count))
        #expect(await reloaded.tipHash == tipAfterVector)
        #expect(await reloaded.tipWork == workAfterVector)
        #expect(await reloaded.blockHash(at: cp.height + 1) == next.hash)
        #expect(await reloaded.header(at: cp.height - 1) == nil)
    }

    @Test("turning verification on refuses the checkpoint-rooted file instead of misreading it",
          arguments: Self.shippedCheckpoints)
    func genesisRefusesCheckpointFile(_ shipped: Shipped) async throws {
        let params = NetworkParams.params(for: shipped.network)
        let cp = try #require(params.checkpoint)
        let url = tempURL("checkpoint-then-genesis-\(shipped.network.rawValue)")
        defer { try? FileManager.default.removeItem(at: url) }

        let chain = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(try await chain.connect([try BlockHeader.decode(shipped.nextHeader)]).appended == 1)

        // The file is not damaged; it just answers a different question. Saying
        // so lets the app rebuild rather than treat block 900,000 as block 0.
        #expect(throws: HeaderChainError.startMismatch(stored: cp.height, wanted: 0)) {
            _ = try HeaderChain(params: params, storageURL: url, start: .genesis)
        }
    }

    @Test("turning verification off keeps a chain that was already verified from genesis",
          arguments: Self.shippedCheckpoints)
    func checkpointAcceptsGenesisFile(_ shipped: Shipped) async throws {
        let params = NetworkParams.params(for: shipped.network)
        let url = tempURL("genesis-then-checkpoint-\(shipped.network.rawValue)")
        defer { try? FileManager.default.removeItem(at: url) }
        // A genesis-rooted file holding nothing but block 0: a count, then
        // this network's real genesis header, which the loader proof-of-work
        // and lineage checks like any other. Writing it by hand is what makes
        // the reopen below read a stored file rather than build a fresh chain
        // — which is the whole case, now that both networks ship a checkpoint
        // the setting could otherwise start from.
        var stored = Data()
        stored.appendUInt32(1)
        stored.append(HeaderChain.genesisHeader(for: params).serialized)
        try stored.write(to: url)

        let chain = try HeaderChain(params: params, storageURL: url, start: .genesis)
        #expect(await chain.startHeight == 0)

        // A chain validated from block 0 already satisfies everything a
        // checkpoint start claims, so switching the setting must not throw it
        // away and re-sync.
        let reopened = try HeaderChain(params: params, storageURL: url, start: .checkpoint)
        #expect(await reopened.startHeight == 0)
        #expect(await reopened.height == 0)
        #expect(await reopened.tip == HeaderChain.genesisHeader(for: params))
    }

    // MARK: - Checkpoint start policy
    //
    // Choosing where to start for a given wallet (#89 phase 3).
    //
    // This is the rule that keeps a speed optimisation from becoming a wrong
    // balance, so it is worth stating case by case.

    @Test("no wallet yet: the checkpoint is free to use", arguments: Self.shippedCheckpoints)
    func noWallet(_ shipped: Shipped) throws {
        let cp = try constant(shipped)
        #expect(HeaderChain.Start.forWallet(birthday: nil, checkpoint: cp,
                                            verifyFromGenesis: false) == .checkpoint)
    }

    @Test("a wallet born at or after the checkpoint keeps the fast path",
          arguments: Self.shippedCheckpoints)
    func modernWallet(_ shipped: Shipped) throws {
        let cp = try constant(shipped)
        #expect(HeaderChain.Start.forWallet(birthday: cp.height, checkpoint: cp,
                                            verifyFromGenesis: false) == .checkpoint)
        #expect(HeaderChain.Start.forWallet(birthday: cp.height + 50_000, checkpoint: cp,
                                            verifyFromGenesis: false) == .checkpoint)
    }

    @Test("a wallet older than the checkpoint gets the whole chain, setting or not",
          arguments: Self.shippedCheckpoints)
    func olderWalletOverridesTheDefault(_ shipped: Shipped) throws {
        // The blocks holding its coins are below the checkpoint, and filters
        // are fetched by block hash — a checkpoint-rooted chain simply cannot
        // ask about them. Reporting a balance short by whatever is down there
        // would be worse than a slow first launch.
        let cp = try constant(shipped)
        #expect(HeaderChain.Start.forWallet(birthday: 0, checkpoint: cp,
                                            verifyFromGenesis: false) == .genesis)
        #expect(HeaderChain.Start.forWallet(birthday: cp.height - 1, checkpoint: cp,
                                            verifyFromGenesis: false) == .genesis)
    }

    @Test("the setting always wins toward more verification, never toward less",
          arguments: Self.shippedCheckpoints)
    func settingOnlyAddsWork(_ shipped: Shipped) throws {
        let cp = try constant(shipped)
        for birthday: UInt32? in [nil, 0, cp.height, cp.height + 1] {
            #expect(HeaderChain.Start.forWallet(birthday: birthday, checkpoint: cp,
                                                verifyFromGenesis: true) == .genesis)
        }
    }

    @Test("a network with no checkpoint always starts at genesis")
    func noCheckpoint() {
        // Neither public network is this case any more, so name the ones that
        // are: a custom BIP325 signet, and the chains the tests mine.
        #expect(NetworkParams.customSignet(challenge: Data([0x51, 0x51])).checkpoint == nil)
        #expect(makeSyntheticChain(length: 1, watchHeight: 1).params.checkpoint == nil)
        #expect(HeaderChain.Start.forWallet(birthday: 900_000, checkpoint: nil,
                                            verifyFromGenesis: false) == .genesis)
    }

    // MARK: - Header replay
    //
    // A `headers` message the peer sent on its own — the BIP130 announcement
    // of a new block — or a reply that was still waiting when its request had
    // already been answered from the backlog, used to be handed back as the
    // answer to the next getheaders. The chain then read one already-known
    // header as a competing branch with no more work, and the pool condemned
    // the peer for the session. Found by the storefront capture on the signet
    // fixture, where the only peer was the user's own node.

    @Test("a headers message that arrived before the request is not its reply")
    func staleBacklogIsNotTheReply() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 8)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = PeerConnection(endpoint: await node.endpoint, params: synthetic.params)
        try await peer.connect()
        defer { Task { await peer.disconnect() } }

        // The node announces its tip, unasked, and the announcement lands in
        // the connection's backlog before anyone asks for headers.
        try await node.send(.headers([synthetic.blocks[6].header]))
        try await Task.sleep(for: .milliseconds(200))

        // Asked from genesis, the node's real answer is the whole chain.
        let locator = GetHeadersMessage(version: PeerConnection.protocolVersion,
                                        locatorHashes: [synthetic.blocks[0].hash])
        let reply = try await peer.request(.getheaders(locator), expecting: ["headers"])
        guard case let .headers(batch) = reply else {
            Issue.record("expected headers, got \(reply.command)")
            return
        }
        #expect(batch.count == 6, "the announcement was returned in place of the reply")
        #expect(batch.first?.hash == synthetic.blocks[1].hash)
    }

    @Test("announcements and stale replies do not stall or condemn a header sync")
    func syncSurvivesReplayedHeaders() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 8)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = PeerConnection(endpoint: await node.endpoint, params: synthetic.params)
        try await peer.connect()
        defer { Task { await peer.disconnect() } }
        let chain = try HeaderChain(params: synthetic.params)

        // First sync from genesis, with the tip announced twice beforehand.
        try await node.send(.headers([synthetic.blocks[6].header]))
        try await node.send(.headers([synthetic.blocks[6].header]))
        try await Task.sleep(for: .milliseconds(200))
        let first = try await chain.sync(using: peer)
        #expect(first.connected == 6)
        #expect(await chain.height == 6)

        // Already at the tip: a stale copy of a lower header and another
        // announcement of the tip sit in the backlog. Neither is news, and
        // neither is a branch.
        try await node.send(.headers([synthetic.blocks[5].header]))
        try await node.send(.headers([synthetic.blocks[6].header]))
        try await Task.sleep(for: .milliseconds(200))
        let second = try await chain.sync(using: peer)
        #expect(second.connected == 0)
        #expect(second.minForkHeight == nil)
        #expect(await chain.height == 6)
        #expect(await chain.tipHash == synthetic.blocks[6].hash)
    }

    @Test("a peer on the losing block of a race is not condemned")
    func staleSiblingIsAStateNotALie() async throws {
        // Our chain has the winning block 6; the peer's ends in a sibling of
        // it, mined on the same parent with the same work. Its every reply
        // to getheaders is that sibling, which no backlog purge can hide.
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 8)
        let parent = synthetic.blocks[5]
        let sibling = minedHeader(previousHash: parent.hash,
                                  merkleRoot: Data(repeating: 0xEE, count: 32),
                                  time: synthetic.blocks[6].header.time + 1)
        let losingChain = Array(synthetic.blocks[0 ... 5])
            + [Block(header: sibling, transactions: synthetic.blocks[6].transactions)]
        let node = LoopbackNode(params: synthetic.params, chain: losingChain)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = PeerConnection(endpoint: await node.endpoint, params: synthetic.params)
        try await peer.connect()
        defer { Task { await peer.disconnect() } }

        let chain = try HeaderChain(params: synthetic.params)
        try await chain.connect(synthetic.blocks.dropFirst().map(\.header))
        #expect(await chain.height == 6)

        let outcome = try await chain.sync(using: peer)
        #expect(outcome.connected == 0)
        #expect(outcome.minForkHeight == nil)
        #expect(outcome.staleSiblings == HeaderChain.maxReplayedBatches + 1)
        #expect(await chain.height == 6)
        #expect(await chain.tipHash == synthetic.blocks[6].hash, "the winning block stays the tip")
    }

    @Test("a lighter branch longer than one block is still a fault")
    func lighterLongerBranchIsStillAFault() async throws {
        // Two blocks forking two below the tip, equal work: not the shape
        // of a race, and the chain keeps refusing it as before.
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 8)
        let headerChain = try HeaderChain(params: synthetic.params)
        try await headerChain.connect(synthetic.blocks.dropFirst().map(\.header))
        let first = minedHeader(previousHash: synthetic.blocks[4].hash,
                                merkleRoot: Data(repeating: 0xEE, count: 32), time: 1_600_090_000)
        let second = minedHeader(previousHash: first.hash,
                                 merkleRoot: Data(repeating: 0xEF, count: 32), time: 1_600_090_600)
        await #expect(throws: HeaderChainError.reorgWithoutMoreWork) {
            try await headerChain.connect([first, second])
        }
        #expect(await headerChain.tipHash == synthetic.blocks[6].hash)
    }

    // MARK: - Reorg visibility
    //
    // A reorg must not be silent (epic #100, invariant S5).
    //
    // `connect` returns how many headers it appended and nothing else, so an
    // ordinary extension and a branch swap that disconnected blocks look
    // identical to the caller. That matters because the wallet scans forward
    // only: once its frontier has passed a height it never revisits it. If a
    // reorg removes a block the wallet already credited, and nothing says so,
    // the wallet keeps describing a branch that no longer exists — a payment
    // stays "confirmed" and a coin stays spendable when neither is true on
    // chain.
    //
    // The reporting used to be a sticky `lastReorg` property, which was the
    // wrong shape twice over: a consumer could read the same value again after
    // later ordinary syncs and roll back a second time, and two swaps inside
    // one sync collapsed into whichever happened last, losing the deeper one. A
    // batch now reports its own fork height, and a sync reports the lowest it
    // saw.

    /// Builds a branch of `count` headers descending from `parent`. The tag
    /// makes each branch's hashes distinct.
    static func branch(from parent: Data, count: Int, tag: UInt8, fromTime time: UInt32) -> [BlockHeader] {
        var headers: [BlockHeader] = []
        var previous = parent
        for index in 0 ..< count {
            let header = minedHeader(previousHash: previous,
                                     merkleRoot: Data(repeating: tag, count: 32),
                                     time: time + UInt32(index) * 600)
            headers.append(header)
            previous = header.hash
        }
        return headers
    }

    /// An ordinary sync is not a reorg and must not look like one.
    @Test("extending the tip records no reorg")
    func plainExtensionRecordsNothing() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        let extension_ = Self.branch(from: chain.blocks[0].hash, count: 4,
                                     tag: 0xAA, fromTime: 1_600_010_000)
        let outcome = try await headerChain.connect(extension_)
        #expect(await headerChain.height == 4)
        #expect(outcome.forkHeight == nil)
        #expect(outcome.appended == 4)
    }

    /// A branch swap reports where the branches diverged and how much was
    /// thrown away — the two facts a consumer needs in order to rewind.
    @Test("a branch swap reports its fork height and how much it disconnected")
    func branchSwapIsReported() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        let original = Self.branch(from: chain.blocks[0].hash, count: 3,
                                   tag: 0xAA, fromTime: 1_600_010_000)
        let extended = try await headerChain.connect(original)
        #expect(await headerChain.height == 3)
        #expect(extended.forkHeight == nil)

        // A competing branch from genesis that ends up longer.
        let longer = Self.branch(from: chain.blocks[0].hash, count: 5,
                                 tag: 0xCC, fromTime: 1_600_030_000)
        let swap = try await headerChain.connect(longer)

        #expect(swap.forkHeight == 0, "both branches descend from genesis")
        #expect(swap.disconnectedHeaders == 3, "all three original headers were disconnected")
        #expect(await headerChain.height == 5)
        #expect(await headerChain.tipHash == longer[4].hash)
    }

    /// A refused reorg changes nothing, so it must not be reported either —
    /// otherwise a consumer would rewind for a branch that was rejected.
    @Test("a refused reorg is not reported")
    func refusedReorgIsNotReported() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        _ = try await headerChain.connect(Self.branch(from: chain.blocks[0].hash, count: 3,
                                                      tag: 0xAA, fromTime: 1_600_010_000))

        let shorter = Self.branch(from: chain.blocks[0].hash, count: 2,
                                  tag: 0xBB, fromTime: 1_600_020_000)
        await #expect(throws: HeaderChainError.reorgWithoutMoreWork) {
            _ = try await headerChain.connect(shorter)
        }
        #expect(await headerChain.height == 3, "the refused branch changed nothing")

        // Nothing was reported because nothing was returned: a throw carries no
        // outcome, so there is no value a consumer could rewind on. The next
        // ordinary batch confirms the refusal left no residue behind it.
        let afterwards = try await headerChain.connect(
            Self.branch(from: (await headerChain.tipHash), count: 1,
                        tag: 0xEE, fromTime: 1_600_040_000))
        #expect(afterwards.forkHeight == nil,
                "a branch that was refused must not look like one that was applied")
        #expect(await headerChain.height == 4)
    }

    /// Two swaps in one sync must not collapse into the shallower one.
    ///
    /// This is the case the sticky property got wrong: it kept whichever
    /// happened last, so a sync that first forked at height 0 and then at
    /// height 1 reported 1, and a rollback to 1 would leave everything above
    /// height 0 from the discarded branch in place. Taking the minimum is what
    /// makes collapsing harmless.
    @Test("a sync reports the lowest fork of several")
    func syncReportsTheLowestFork() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        _ = try await headerChain.connect(Self.branch(from: chain.blocks[0].hash, count: 2,
                                                      tag: 0xAA, fromTime: 1_600_010_000))

        var outcome = HeaderChain.SyncOutcome()

        // Deeper swap first: forks at the genesis block, height 0.
        let second = Self.branch(from: chain.blocks[0].hash, count: 4,
                                 tag: 0xCC, fromTime: 1_600_030_000)
        outcome.absorb(try await headerChain.connect(second))
        #expect(outcome.minForkHeight == 0)

        // Then a shallower one, forking at height 1.
        let third = Self.branch(from: second[0].hash, count: 6,
                                tag: 0xDD, fromTime: 1_600_050_000)
        outcome.absorb(try await headerChain.connect(third))
        #expect(outcome.minForkHeight == 0,
                "the shallower swap must not hide the deeper one")
        #expect(outcome.disconnectedHeaders == 5)
    }
}
