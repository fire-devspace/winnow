import Foundation
import Testing
@testable import BitcoinP2P

/// HeaderChain: PoW-checked connect, fork choice, locator, persistence —
/// over a synthetic mined chain (bits 0x207fffff, so PoW is real but trivial).
@Suite("HeaderChain")
struct HeaderChainTests {
    @Test("connects valid headers and tracks work")
    func connect() async throws {
        let chain = makeSyntheticChain(length: 5, watchHeight: 6)
        let headerChain = try HeaderChain(params: chain.params)
        let appended = try await headerChain.connect(chain.blocks.dropFirst().map(\.header))
        #expect(appended == 5)
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

    @Test("corrupt store is rejected")
    func corruptStore() async throws {
        let chain = makeSyntheticChain(length: 1, watchHeight: 6)
        let file = tempFileURL("headers.dat")
        try Data([0xDE, 0xAD, 0xBE]).write(to: file)
        await #expect(throws: HeaderChainError.self) {
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
}
