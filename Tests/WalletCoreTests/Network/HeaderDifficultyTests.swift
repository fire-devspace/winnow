import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Header difficulty")
struct HeaderDifficultyTests {
    // Bitcoin Core v31.0 src/test/pow_tests.cpp: independently fixed answers,
    // including the powLimit and both timespan clamps.
    @Test("Core retarget vectors", arguments: [
        (UInt32(32_256), UInt32(1_261_130_161), UInt32(1_262_152_739), UInt32(0x1D00_FFFF), UInt32(0x1D00_D86A)),
        (2_016, 1_231_006_505, 1_233_061_996, 0x1D00_FFFF, 0x1D00_FFFF),
        (68_544, 1_279_008_237, 1_279_297_671, 0x1C05_A3F4, 0x1C01_68FD),
        (46_368, 1_263_163_443, 1_269_211_443, 0x1C38_7F6F, 0x1D00_E1FD),
        // A reversed timestamp must clamp, not underflow an unsigned value.
        (68_544, 1_279_008_237, 1_279_008_236, 0x1C05_A3F4, 0x1C01_68FD),
    ])
    func coreRetarget(height: UInt32, firstTime: UInt32, lastTime: UInt32,
                      bits: UInt32, expected: UInt32) throws {
        let first = header(time: firstTime, bits: bits)
        let previous = header(time: lastTime, bits: bits)
        #expect(try HeaderChain.expectedBits(height: height, previous: previous,
                                            periodFirst: first, params: .mainnet) == expected)
    }

    @Test("real mainnet adjustments and the missing checkpoint history")
    func realHeaders() throws {
        struct Boundary: Decodable { let height: UInt32; let first: String; let previous: String; let next: String }
        let url = try #require(Bundle.module.url(forResource: "difficulty-boundaries", withExtension: "json",
                                                 subdirectory: "Vectors"))
        let vectors = try JSONDecoder().decode([Boundary].self, from: Data(contentsOf: url))
        #expect(vectors.map(\.height) == [32_256, 901_152])
        for vector in vectors {
            let first = try BlockHeader.decode(#require(Data(hex: vector.first)))
            let previous = try BlockHeader.decode(#require(Data(hex: vector.previous)))
            let next = try BlockHeader.decode(#require(Data(hex: vector.next)))
            #expect(next.previousHash == previous.hash)
            for item in [first, previous, next] {
                _ = try HeaderChain.checkedWork(for: item, params: .mainnet, height: vector.height)
            }
            #expect(try HeaderChain.expectedBits(height: vector.height, previous: previous,
                                                periodFirst: first, params: .mainnet) == next.bits)
            #expect(try HeaderChain.expectedBits(height: vector.height, previous: previous,
                                                periodFirst: nil, params: .mainnet) == nil)
            #expect(try HeaderChain.expectedBits(height: vector.height + 1, previous: next,
                                                periodFirst: nil, params: .mainnet) == next.bits)
        }
    }

    @Test("compact encoding normalizes truncation and the sign bit", arguments: [
        (UInt32(0x0100_3456), UInt32(0)), (0x0112_3456, 0x0112_0000),
        (0x0200_8000, 0x0200_8000), (0x0300_9234, 0x0300_9234),
        (0x0412_3456, 0x0412_3456), (0x1D00_FFFF, 0x1D00_FFFF),
        (0x1E03_77AE, 0x1E03_77AE), (0x2100_FFFF, 0x2100_FFFF),
    ])
    func compact(bits: UInt32, expected: UInt32) throws {
        #expect(try #require(UInt256.target(compact: bits)).compact == expected)
    }

    @Test("retarget arithmetic carries across limbs and encodes large targets")
    func arithmetic() {
        let twoTo64 = UInt256(1).shiftedLeft(64)
        #expect(UInt256(UInt64.max).multiplied(by: 2) == twoTo64 + twoTo64 - UInt256(2))
        #expect(UInt256.max.multiplied(by: 2) == UInt256.max - UInt256(1))
        #expect(UInt256.max.shiftedRight(256).isZero)
        #expect(twoTo64.shiftedRight(64) == UInt256(1))
        #expect(twoTo64.shiftedRight(63) == UInt256(2))
        #expect(UInt256.max.bitWidth == 256)
        #expect(UInt256.max.compact == 0x2100_FFFF)
    }

    @Test("both networks fit retarget multiplication and cap at powLimit", arguments: [NetworkParams.mainnet, .signet])
    func networkLimits(params: NetworkParams) throws {
        #expect(params.difficultyAdjustmentInterval == 2_016)
        let largestTimespan = params.powTargetTimespan * 4
        let limit = UInt256(littleEndian: params.powLimit)
        #expect(limit <= UInt256.max.quotientAndRemainder(dividingBy: UInt256(UInt64(largestTimespan))).quotient)
        #expect(try HeaderChain.expectedBits(height: 2_016,
                                            previous: header(time: largestTimespan, bits: params.genesisBits),
                                            periodFirst: header(time: 0, bits: params.genesisBits),
                                            params: params) == params.genesisBits)
    }

    @Test("adjustments are checked across batches and after reload", arguments: [[9], [2, 5, 9]])
    func appendAndReload(ends: [Int]) async throws {
        let blocks = try chain()
        let params = parameters(genesis: blocks[0])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try HeaderChain(params: params, storageURL: file)
        var start = 1
        for end in ends {
            try await store.connect(Array(blocks[start...end]))
            start = end + 1
        }
        let reloaded = try HeaderChain(params: params, storageURL: file)
        #expect(await reloaded.tipHash == blocks[9].hash)
        #expect(await reloaded.tipWork == store.tipWork)
    }

    @Test("a mined wrong adjustment rejects the whole batch")
    func rejectsAdjustment() async throws {
        let blocks = try chain()
        let store = try HeaderChain(params: parameters(genesis: blocks[0]))
        let wrong = try mine(previous: blocks[3], time: 1_004, bits: blocks[3].bits)
        await #expect(throws: HeaderChainError.unexpectedDifficulty(height: 4)) {
            try await store.connect(Array(blocks[1...3]) + [wrong])
        }
        #expect(await store.height == 0)
        try await store.connect(Array(blocks.dropFirst()))
        #expect(await store.height == 9)
    }

    @Test("saved headers cannot bypass difficulty checks", arguments: [3, 4])
    func rejectsStoredDifficulty(height: Int) throws {
        let blocks = try chain()
        let wrong = try mine(previous: blocks[height - 1], time: UInt32(1_000 + height), bits: 0x201F_FFFE)
        var data = Data()
        data.appendUInt32(UInt32(height + 1))
        for block in blocks[..<height] + [wrong] { data.append(block.serialized) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        #expect(throws: HeaderChainError.unexpectedDifficulty(height: UInt32(height))) {
            _ = try HeaderChain(params: parameters(genesis: blocks[0]), storageURL: file)
        }
    }

    @Test("only the incomplete checkpoint period is skipped")
    func checkpoint() async throws {
        let blocks = try chain()
        let checkpoint = NetworkParams.Checkpoint(height: 1, header: blocks[1].serialized,
                                                  chainwork: UInt256(16).bigEndianData)
        let store = try HeaderChain(params: parameters(genesis: blocks[0], checkpoint: checkpoint), start: .checkpoint)
        try await store.connect(Array(blocks[2...7]))
        let wrong = try mine(previous: blocks[7], time: 1_008, bits: blocks[7].bits)
        await #expect(throws: HeaderChainError.unexpectedDifficulty(height: 8)) {
            try await store.connect([wrong])
        }
        try await store.connect(Array(blocks[8...9]))
        #expect(await store.height == 9)
    }

    @Test("a replacement uses its own period start, not the old branch's")
    func branchPeriodStart() async throws {
        let blocks = try chain()
        let store = try HeaderChain(params: parameters(genesis: blocks[0]))
        try await store.connect(Array(blocks[1...8]))
        var branch = [try mine(previous: blocks[3], time: 1_003, bits: 0x2017_FFFF)]
        for height in 5...10 {
            branch.append(try mine(previous: branch.last, time: UInt32(1_000 + height), bits: 0x2017_FFFF))
        }
        let wrong = try mine(previous: branch[3], time: 1_008, bits: blocks[8].bits)
        await #expect(throws: HeaderChainError.unexpectedDifficulty(height: 8)) {
            try await store.connect(Array(branch.prefix(4)) + [wrong])
        }
        #expect(await store.tipHash == blocks[8].hash)
        let result = try await store.connect(branch)
        #expect(result.forkHeight == 3)
        #expect(await store.tipHash == branch.last?.hash)
    }

    private func header(time: UInt32, bits: UInt32) -> BlockHeader {
        BlockHeader(version: 1, previousHash: Data(repeating: 0, count: 32),
                    merkleRoot: Data(repeating: 0, count: 32), time: time, bits: bits, nonce: 0)
    }

    private func parameters(genesis: BlockHeader, checkpoint: NetworkParams.Checkpoint? = nil) -> NetworkParams {
        let base = makeTestParams(genesis: genesis)
        return NetworkParams(network: base.network, magic: base.magic, defaultPort: base.defaultPort,
                             genesisTime: genesis.time, genesisBits: genesis.bits, genesisNonce: genesis.nonce,
                             genesisMerkleRoot: genesis.merkleRoot, genesisHash: genesis.hash,
                             powLimit: base.powLimit, dnsSeeds: [], checkpoint: checkpoint,
                             powTargetTimespan: 4, powTargetSpacing: 1)
    }

    private func mine(previous: BlockHeader? = nil, time: UInt32, bits: UInt32) throws -> BlockHeader {
        let target = try #require(UInt256.target(compact: bits))
        for nonce in UInt32.min...UInt32.max {
            let block = BlockHeader(version: 1, previousHash: previous?.hash ?? Data(repeating: 0, count: 32),
                                    merkleRoot: Data(repeating: 0xD4, count: 32), time: time, bits: bits, nonce: nonce)
            if UInt256(littleEndian: block.hash) <= target { return block }
        }
        throw HeaderChainError.insufficientProofOfWork(height: 0)
    }

    private func chain() throws -> [BlockHeader] {
        var result: [BlockHeader] = []
        for height in 0...9 {
            let bits: UInt32 = height < 4 ? 0x201F_FFFF : height < 8 ? 0x2017_FFFF : 0x2011_FFFF
            result.append(try mine(previous: result.last, time: UInt32(1_000 + height), bits: bits))
        }
        return result
    }
}
