@testable import WalletCore
import Foundation
import Testing
import TestSupport

/// The BIP157 client path against the dev node over real P2P: header sync
/// to the node's tip, then the cfcheckpt → cfheaders → cfilters flow with a
/// script the node itself served, and a fresh wallet scanning forward to
/// the tip with its fee floor resolved from the node's BIP133 `feefilter`.
///
/// These assertions used to live in two suites gated on `WINNOW_SIGNET`
/// (`SignetIntegrationTests`, `SignetWalletIntegrationTests`) that dialed a
/// hardcoded public-signet node on 127.0.0.1:38333 and returned early when
/// it was absent. No workflow set the variable, so they never ran. They
/// live here now, next to the other suites that drive the node through the
/// `TestSupport` harness (the miner and the RPC helper).
@Suite("filter sync differential", .enabled(if: diffEnabled))
struct FilterSyncDiffTests {
    private let params = NetworkParams.customSignet(challenge: BitcoinCLI.challenge,
                                                    defaultPort: BitcoinCLI.p2pPort)
    private let endpoint = PeerEndpoint(host: BitcoinCLI.nodeHost, port: BitcoinCLI.p2pPort)

    @Test("cfcheckpt / cfheaders / cfilters from height 100, with a real match")
    func filterFlowMatchesARealScript() async throws {
        try await SignetMiner.ensureChainHeight(atLeast: 101)
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let synced = try await syncHeaders(over: pool)
        #expect(await synced.peer.peerStartHeight == Int32(synced.tip),
                "the node's version start height is its tip")

        // Learn a real scriptPubKey from block 100 by fetching the block
        // itself over `getdata`; the filter for that block must then match.
        let targetHeight: UInt32 = 100
        let targetHash = try #require(await synced.chain.blockHash(at: targetHeight))
        let served = try await fetchBlock(targetHash, from: synced.peer)
        let block = try #require(served, "node did not serve block \(targetHeight)")
        #expect(block.hash == targetHash, "served block is the one requested")
        let watchScript = try #require(firstFilterableScript(in: block),
                                       "block \(targetHeight) has no filterable output")

        let sync = try FilterSync(pool: pool, chain: synced.chain, startHeight: targetHeight,
                                  requiredCheckpointPeers: 1)
        let collector = MatchCollector()
        try await sync.sync(watchScripts: [watchScript]) { match in
            collector.add(match)
        }
        #expect(collector.matches.contains { $0.height == targetHeight },
                "filter match at \(targetHeight)")
        #expect(collector.matches.allSatisfy { $0.height >= targetHeight },
                "no match below the start height")
        #expect(await sync.lastScannedHeight == synced.tip, "scanned through the tip")
    }

    @Test("a fresh wallet below the tip scans forward to it with the node's fee floor")
    func freshWalletScansForwardToTheTip() async throws {
        try await SignetMiner.ensureChainHeight(atLeast: 101)
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let synced = try await syncHeaders(over: pool)
        let tip = synced.tip

        // A fresh wallet created a few blocks below the tip: the scan must
        // run forward over those blocks without error and land at the tip.
        let creationHeight = tip - 5
        let wallet = try await Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                             storageURL: tempFileURL("wallet.json"),
                                             creationHeight: creationHeight)
        let sync = try FilterSync(pool: pool, chain: synced.chain, startHeight: creationHeight,
                                  storageURL: tempFileURL("filters.json"),
                                  requiredCheckpointPeers: 1)
        try await sync.sync(watchScripts: wallet.watchScripts()) { match in
            _ = try await wallet.apply(match: match)
        }
        try await wallet.recordScanHeight(sync.nextScanHeight)
        #expect(await wallet.nextScanHeight == tip + 1, "scan frontier is one past the tip")
        #expect(await wallet.balance == 0, "a fresh key owns nothing")
        #expect(await sync.lastScannedHeight == tip, "filter frontier reached the tip")

        // The floor resolves through the FeePolicy pipeline from the peer's
        // BIP133 `feefilter` (sat/kvB). Core sends that in its first
        // SendMessages pass after the handshake, as max(rounded mempool min
        // fee, minrelaytxfee); `getmempoolinfo.mempoolminfee` is max(mempool
        // min fee, minrelaytxfee). The two differ only once the mempool has
        // hit its size limit and the rounder (10% buckets, randomised) is in
        // play, which a disposable fixture never reaches, so the RPC value is
        // comparable and the comparison is exact. The announced value is
        // checked first, so a conversion bug in FeePolicy cannot hide behind
        // a lucky RPC agreement.
        let observed = try await feeFilterFloor(of: pool)
        let floor = try #require(observed, "the node never sent feefilter")
        let announced = await synced.peer.feeFilter
        let announcedSatPerKvB = try #require(announced, "connection holds no feefilter")
        #expect(floor == Double(announcedSatPerKvB) / 1_000, "sat/kvB → sat/vB conversion")
        #expect(floor == (try nodeFeeFloorSatPerVByte()), "floor equals getmempoolinfo.mempoolminfee")
    }

    // MARK: - Helpers

    /// The pool's one connection with our header chain synced over it, plus
    /// the node's own tip so every assertion compares against what the node
    /// says rather than against what we synced.
    private func syncHeaders(over pool: PeerPool) async throws
        -> (peer: PeerConnection, chain: HeaderChain, tip: UInt32)
    {
        let peers = await pool.connectedPeers()
        let peer = try #require(peers.first, "no connection to \(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)")
        let chain = try HeaderChain(params: params, storageURL: tempFileURL("headers.bin"))
        try await chain.sync(using: peer, timeout: .seconds(60))
        let tip = try UInt32(BitcoinCLI.blockCount())
        #expect(await chain.height == tip, "header sync tip")
        #expect(await chain.tipHash.displayHex == (try BitcoinCLI.bestBlockHash()), "tip hash")
        return (peer, chain, tip)
    }

    /// Block `hash` as the node serves it over P2P (`getdata` with the
    /// witness flag), or nil when it answers `notfound`.
    private func fetchBlock(_ hash: Data, from peer: PeerConnection) async throws -> Block? {
        let response = try await peer.request(
            .getdata(InventoryPayload([InventoryVector(type: .witnessBlock, hash: hash)])),
            expecting: ["block", "notfound"], timeout: .seconds(60))
        guard case let .block(block) = response else { return nil }
        return block
    }

    /// The first output script in `block` that BIP158 puts in the basic
    /// filter: non-empty and not OP_RETURN.
    private func firstFilterableScript(in block: Block) -> Data? {
        block.transactions
            .flatMap { $0.outputs.map(\.scriptPubKey) }
            .first { !$0.isEmpty && $0.first != 0x6A }
    }

    /// The pool's BIP133 floor, waiting briefly for the node's `feefilter`.
    /// It is normally long in by the time a scan has finished; the wait is
    /// for a slow node, not a missing message.
    private func feeFilterFloor(of pool: PeerPool) async throws -> Double? {
        for _ in 0 ..< 100 where await pool.feeFilterFloorSatPerVByte() == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        return await pool.feeFilterFloorSatPerVByte()
    }

    /// `getmempoolinfo.mempoolminfee` (BTC/kvB) as sat/vB, through the same
    /// exact-sats conversion the other differential checks use.
    private func nodeFeeFloorSatPerVByte() throws -> Double {
        let info = try BitcoinCLI.runObject(["getmempoolinfo"])
        let minFee = try #require(info["mempoolminfee"], "getmempoolinfo.mempoolminfee")
        return Double(try BitcoinCLI.sats(minFee)) / 1_000
    }
}
