import Foundation
import Testing
@testable import BitcoinP2P

/// Integration against the local signet node (127.0.0.1:38333).
///
/// OPT-IN ONLY: runs only when WINNOW_SIGNET=1 is set in the environment.
/// The node must run with -blockfilterindex=1 -peerblockfilters=1; without
/// them it will not signal NODE_COMPACT_FILTERS and every test here skips
/// cleanly instead of failing.
private let signetEnabled = ProcessInfo.processInfo.environment["WINNOW_SIGNET"] == "1"

@Suite("Signet node integration", .enabled(if: signetEnabled))
struct SignetIntegrationTests {
    /// Connects to the local node, or returns nil (→ skip) when the node is
    /// down or not serving compact filters.
    private func connectToNode() async -> PeerConnection? {
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "127.0.0.1", port: 38_333),
                                  params: .signet)
        do {
            try await peer.connect(timeout: .seconds(5))
            return peer
        } catch {
            // Node down, or blockfilterindex not enabled — expected; skip.
            return nil
        }
    }

    @Test("headers sync from genesis to the signet tip")
    func headerSync() async throws {
        guard let peer = await connectToNode() else { return }
        let chain = try HeaderChain(params: .signet)
        try await chain.sync(using: peer, timeout: .seconds(60))
        let height = await chain.height
        #expect(height > 0)
        let peerHeight = await peer.peerStartHeight
        #expect(Int(height) >= Int(peerHeight) - 10)
        await peer.disconnect()
    }

    @Test("cfcheckpt / cfheaders / cfilters for a small range, with a real match")
    func filterFlow() async throws {
        guard let peer = await connectToNode() else { return }

        // Pick a low height and learn a real scriptPubKey from that block by
        // fetching it directly — the filter for the block must then match.
        let pool = PeerPool(params: .signet, peerCount: 1,
                            manualPeers: [PeerEndpoint(host: "127.0.0.1", port: 38_333)])
        await pool.start()
        let chain = try HeaderChain(params: .signet)
        try await chain.sync(using: peer, timeout: .seconds(60))
        let tip = await chain.height
        guard tip >= 100 else {
            await pool.stop()
            return
        }
        let targetHeight: UInt32 = 100
        let targetHash = try #require(await chain.blockHash(at: targetHeight))
        let blockResponse = try await peer.request(
            .getdata(InventoryPayload([InventoryVector(type: .witnessBlock, hash: targetHash)])),
            expecting: ["block", "notfound"], timeout: .seconds(60))
        guard case let .block(block) = blockResponse else {
            Issue.record("node did not serve block at \(targetHeight)")
            await pool.stop()
            return
        }
        let watchScript = block.transactions
            .flatMap { $0.outputs.map(\.scriptPubKey) }
            .first { !$0.isEmpty && $0.first != 0x6A }!

        let sync = try FilterSync(pool: pool, chain: chain, startHeight: targetHeight,
                                  requiredCheckpointPeers: 1)
        let collector = MatchCollector()
        try await sync.sync(watchScripts: [watchScript]) { match in
            collector.add(match)
        }
        #expect(collector.matches.contains { $0.height == targetHeight })
        #expect(await sync.lastScannedHeight == tip)

        await pool.stop()
        await peer.disconnect()
    }
}
