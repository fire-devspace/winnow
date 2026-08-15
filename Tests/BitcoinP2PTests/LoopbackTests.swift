import Foundation
import Network
import Testing
@testable import BitcoinP2P

/// Loopback integration: real NWConnection transport against a fake node.
/// No external network — everything runs on 127.0.0.1 listeners.
@Suite("Loopback peers")
struct LoopbackTests {
    @Test("handshake negotiates and tracks peer services")
    func handshake() async throws {
        let node = LoopbackNode(params: .signet, chain: makeSyntheticChain(length: 2, watchHeight: 6).blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet)
        try await peer.connect()
        #expect(await peer.isConnected)
        #expect(await peer.peerServices & PeerConnection.nodeCompactFilters != 0)
        #expect(await peer.peerUserAgent == "/loopback-node:0.1/")
        await peer.disconnect()
        #expect(await !peer.isConnected)
    }

    @Test("peers without NODE_COMPACT_FILTERS are rejected")
    func rejectsNonFilterPeer() async throws {
        let node = LoopbackNode(params: .signet, services: 1) // NODE_NETWORK only
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet)
        do {
            try await peer.connect()
            Issue.record("handshake should have failed")
        } catch let PeerError.missingCompactFilters(services) {
            #expect(services == 1)
        }
    }

    @Test("ping is answered; feefilter push is tracked (BIP133)")
    func pingAndFeeFilter() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet)
        try await peer.connect()
        try await peer.ping() // LoopbackNode answers pongs automatically

        try await node.send(.feefilter(7_500))
        let deadline = ContinuousClock.now + .seconds(5)
        while await peer.feeFilter == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await peer.feeFilter == 7_500)
        await peer.disconnect()
    }

    @Test("a client that resets mid-handshake does not crash the node")
    func clientResetMidHandshake() async throws {
        // Regression: LoopbackNode.handle(_:) resumed its handshake-wait
        // continuation on .ready and cleared stateUpdateHandler, but a .failed
        // (ECONNRESET) state update that was already in flight was delivered
        // anyway — resuming the same continuation twice, a fatal
        // "continuation misuse" crash that took down the whole test process
        // on CI. The ready wait is now guarded by ResumeOnce.
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }
        let endpoint = await node.endpoint

        func connectThenReset(after delay: Duration) async throws {
            let client = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                      port: NWEndpoint.Port(rawValue: endpoint.port)!,
                                      using: .tcp)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeOnce = ResumeOnce(continuation)
                client.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        client.stateUpdateHandler = nil
                        resumeOnce.resume()
                    case let .failed(error):
                        client.stateUpdateHandler = nil
                        resumeOnce.resume(throwing: error)
                    default: break
                    }
                }
                client.start(queue: DispatchQueue(label: "org.btc-swift.tests.rst-client"))
            }
            // Dropping the connection without reading the node's version
            // resets the socket, so the node-side connection fails with
            // ECONNRESET around its handshake wait.
            try await Task.sleep(for: delay)
            client.cancel()
        }

        // Mid-flight resets: the RST lands after the node's wait resumed.
        for _ in 0 ..< 20 {
            try await connectThenReset(after: .milliseconds(50))
        }
        // Immediate resets: the RST races connection setup itself, so .ready
        // and .failed can be delivered back-to-back on the node side — the
        // window that crashed CI.
        for _ in 0 ..< 40 {
            try await connectThenReset(after: .zero)
        }
        // Give the node time to observe the resets (pre-fix this crashed the
        // process here), then prove it still serves a fresh peer.
        try await Task.sleep(for: .milliseconds(200))
        let peer = PeerConnection(endpoint: endpoint, params: .signet)
        try await peer.connect()
        #expect(await peer.isConnected)
        await peer.disconnect()
    }

    @Test("headers sync from genesis to the node tip")
    func headerSync() async throws {
        let synthetic = makeSyntheticChain(length: 8, watchHeight: 6)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: synthetic.params)
        try await peer.connect()
        let chain = try HeaderChain(params: synthetic.params)
        try await chain.sync(using: peer)
        #expect(await chain.height == 8)
        #expect(await chain.tipHash == synthetic.blocks[8].hash)
        await peer.disconnect()
    }

    @Test("full BIP157 flow: checkpoints, pinned headers, filter match, block fetch")
    func filterSync() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        #expect(await pool.connectedPeers().count == 1)

        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("filter-progress.json")
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1)

        let collector = MatchCollector()
        try await sync.sync(watchScripts: [synthetic.watchScript]) { match in
            collector.add(match)
        }
        let matches = collector.matches

        #expect(matches.count == 1)
        #expect(matches[0].height == synthetic.watchHeight)
        #expect(matches[0].blockHash == synthetic.blocks[3].hash)
        #expect(matches[0].block.transactions[0].outputs.contains {
            $0.scriptPubKey == synthetic.watchScript
        })
        #expect(await sync.nextScanHeight == 7)
        // The whole filter header chain got pinned.
        #expect(await sync.filterHeader(at: 6) != nil)

        // Progress persists across instances.
        let reloaded = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                      storageURL: progressFile, requiredCheckpointPeers: 1)
        #expect(await reloaded.nextScanHeight == 7)
        #expect(await reloaded.lastScannedHeight == 6)

        await pool.stop()
        try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent())
    }

    @Test("cfcheckpt headers map to checkpoint multiples, not the tip (Core semantics)")
    func checkpointHeightMapping() async throws {
        // Regression test for a bug caught by the differential harness: Core's
        // ProcessGetCFCheckPt returns headers at heights 1000, 2000, …
        // ascending — never the stop block itself. FilterSync used to map the
        // first header onto the tip and reject every sync past height 1000.
        let synthetic = makeSyntheticChain(length: 1_001, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  requiredCheckpointPeers: 1)
        let collector = MatchCollector()
        try await sync.sync(watchScripts: [synthetic.watchScript]) { match in
            collector.add(match)
        }
        #expect(collector.matches.count == 1)
        #expect(await sync.lastScannedHeight == 1_001)
        // The single checkpoint (height 1000) was pinned and cross-checked.
        #expect(await sync.filterHeader(at: 1_000) != nil)
        await pool.stop()
    }

    @Test("a lying filter fails verification against the pinned header chain")
    func filterTamperingDetected() async throws {
        let synthetic = makeSyntheticChain(length: 4, watchHeight: 6)
        // Node serves honest cfheaders but a bit-flipped cfilter at height 2.
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                corruptFilterAtHeight: 2)
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  requiredCheckpointPeers: 1)
        await #expect(throws: FilterSyncError.filterHeaderMismatch(height: 2)) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        await pool.stop()
    }
}
