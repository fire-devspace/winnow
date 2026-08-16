import BitcoinCore
import BitcoinP2P
import Foundation
import Testing
@testable import WalletCore

/// Wallet integration against the local signet node (127.0.0.1:38333).
///
/// OPT-IN ONLY: runs only when WINNOW_SIGNET=1 is set in the environment.
/// The node must run with -blockfilterindex=1 -peerblockfilters=1; without
/// them it will not signal NODE_COMPACT_FILTERS and every test here skips
/// cleanly instead of failing.
private let signetEnabled = ProcessInfo.processInfo.environment["WINNOW_SIGNET"] == "1"

@Suite("Signet wallet integration", .enabled(if: signetEnabled))
struct SignetWalletIntegrationTests {
    /// Connects to the local node, or returns nil (→ skip) when the node is
    /// down or not serving compact filters.
    private func connectToNode() async -> PeerConnection? {
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "127.0.0.1", port: 38_333),
                                  params: .signet)
        do {
            try await peer.connect(timeout: .seconds(5))
            return peer
        } catch {
            return nil
        }
    }

    @Test("fresh wallet scans forward from (near) the tip and stays consistent")
    func scanFromTip() async throws {
        guard let probe = await connectToNode() else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winnow-wallet-int-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chain = try HeaderChain(params: .signet,
                                    storageURL: dir.appendingPathComponent("headers.bin"))
        try await chain.sync(using: probe, timeout: .seconds(60))
        let tip = await chain.height
        guard tip > 10 else { await probe.disconnect(); return }

        // A fresh wallet created a few blocks below the tip: the scan must run
        // forward over those blocks without error and land at the tip.
        let creationHeight = tip - 5
        let wallet = try await Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                             storageURL: dir.appendingPathComponent("wallet.json"),
                                             creationHeight: creationHeight)
        let pool = PeerPool(params: .signet, peerCount: 1,
                            manualPeers: [PeerEndpoint(host: "127.0.0.1", port: 38_333)])
        await pool.start()
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: creationHeight,
                                  storageURL: dir.appendingPathComponent("filters.json"),
                                  requiredCheckpointPeers: 1)
        try await wallet.scan(using: sync)
        #expect(await wallet.nextScanHeight == tip + 1)
        #expect(await wallet.balance == 0) // a fresh key owns nothing

        // The feefilter floor resolves through the FeePolicy pipeline.
        _ = await pool.feeFilterFloorSatPerVByte()

        await pool.stop()
        await probe.disconnect()
    }
}
