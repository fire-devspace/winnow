import Foundation
import Network
import Testing
import TestSupport
@testable import WalletCore

/// FilterSync end to end, by subject: the happy path over a real loopback
/// transport, what the on-disk progress file may and may not say, how the
/// frontier rewinds under a reorg, and the BIP158 arithmetic underneath it all.
///
/// Merged from `LoopbackTests`, `FilterSyncPersistenceTests`,
/// `FilterProgressRollbackTests` and `FilterMatchingTests`; each `// MARK:`
/// below is one of those suites, in that order. The loopback sections open
/// real 127.0.0.1 listeners — no external network — and the last two sections
/// touch no socket at all.
@Suite("FilterSync")
struct FilterSyncTests {

    // MARK: - Loopback peers

    /// Loopback integration: real NWConnection transport against a fake node.
    /// No external network — everything runs on 127.0.0.1 listeners.
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
                client.start(queue: DispatchQueue(label: "org.winnow.tests.rst-client"))
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

    /// Runs alone and with a second honest peer. The two-peer form is the
    /// positive control for the peer-disagreement cases in
    /// `FilterSyncAdversaryTests`: without it, a refusal there could be the
    /// two-peer path being broken rather than the disagreement being caught.
    @Test("full BIP157 flow: checkpoints, pinned headers, filter match, block fetch",
          arguments: [1, 2])
    func filterSync(peerCount: Int) async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let nodes = (0 ..< peerCount).map { _ in
            LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        }
        for node in nodes { try await node.start() }
        defer { for node in nodes { Task { await node.stop() } } }

        var endpoints: [PeerEndpoint] = []
        for node in nodes { endpoints.append(await node.endpoint) }
        let pool = PeerPool(params: synthetic.params, peerCount: peerCount,
                            manualPeers: endpoints,
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        #expect(await pool.connectedPeers().count == peerCount)

        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("filter-progress.json")
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: peerCount)

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
                                      storageURL: progressFile, requiredCheckpointPeers: peerCount)
        #expect(await reloaded.nextScanHeight == 7)
        #expect(await reloaded.lastScannedHeight == 6)

        await pool.stop()
        try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent())
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

    // MARK: - FilterSync persistence

    @Test("disabled, missing, and valid loaded progress are distinguished")
    func persistenceStates() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-state.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        let disabled = try FilterSync(pool: pool, chain: chain, startHeight: 3)
        #expect(disabled.persistenceState == .disabled)
        #expect(await disabled.nextScanHeight == 3)

        let missing = try FilterSync(pool: pool, chain: chain, startHeight: 3, storageURL: store)
        #expect(missing.persistenceState == .missing)
        #expect(await missing.nextScanHeight == 3)

        try writeProgress(.init(nextScanHeight: 3,
                                filterHeaders: ["2": Data(repeating: 0x11, count: 32).hex]),
                          to: store)
        let loaded = try FilterSync(pool: pool, chain: chain, startHeight: 3, storageURL: store)
        #expect(loaded.persistenceState == .loaded)
        #expect(await loaded.nextScanHeight == 3)
        #expect(await loaded.filterHeader(at: 2) == Data(repeating: 0x11, count: 32))
    }

    @Test("malformed JSON is rejected and its bytes are preserved")
    func malformedJSONPreserved() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-malformed.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        let original = Data(#"{"nextScanHeight":"not-a-number","filterHeaders":{}}"#.utf8)
        try original.write(to: store)

        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
        #expect(try Data(contentsOf: store) == original)
    }

    @Test("an unreadable existing path is not treated as missing progress")
    func unreadableProgress() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-is-a-directory")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)

        #expect(throws: FilterSyncStorageError.unreadable) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test("low frontiers, malformed keys and hashes, and future pins fail closed")
    func invalidProgressFields() throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let store = tempFileURL("filter-invalid-fields.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        try writeProgress(.init(nextScanHeight: 4), to: store)
        #expect(throws: FilterSyncStorageError.frontierBeforeWallet(stored: 4, wallet: 5)) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 5, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5,
                                filterHeaders: ["04": Data(repeating: 1, count: 32).hex]),
                          to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5, filterHeaders: ["4": "abcd"]), to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }

        try writeProgress(.init(nextScanHeight: 5,
                                filterHeaders: ["5": Data(repeating: 2, count: 32).hex]),
                          to: store)
        #expect(throws: FilterSyncStorageError.self) {
            _ = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: store)
        }
    }

    @Test("a forged frontier beyond the validated tip is rejected without rewriting or blaming the peer")
    func frontierBeyondTip() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let store = tempFileURL("filter-forged-frontier.json")
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        try writeProgress(.init(nextScanHeight: 100), to: store)
        let original = try Data(contentsOf: store)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: store, requiredCheckpointPeers: 1)

        await #expect(throws: FilterSyncStorageError.frontierBeyondTip(stored: 100, tip: 6)) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        #expect(await sync.nextScanHeight == 100)
        #expect(try Data(contentsOf: store) == original)
        #expect(await pool.connectedPeers().count == 1)
    }

    @Test("a failed batch write leaves the in-memory frontier and pins unchanged")
    func failedBatchWriteIsTransactional() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let store = tempFileURL("filter-write-failure/progress.json")
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: store, requiredCheckpointPeers: 1)
        try FileManager.default.removeItem(at: store.deletingLastPathComponent())

        await #expect(throws: FilterSyncStorageError.writeFailed) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        #expect(await sync.nextScanHeight == 1)
        #expect(await sync.filterHeader(at: 1) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    private func writeProgress(_ progress: FilterSync.Progress, to url: URL) throws {
        try JSONEncoder().encode(progress).write(to: url, options: .atomic)
    }

    // MARK: - Filter progress rollback

    /// Filter progress rewinds with everything else (#127).
    ///
    /// The frontier is the thing that makes a reorg silent: scanning forward
    /// from a height the wallet has already passed means the orphaned branch is
    /// never re-examined. Rewinding it is what turns the rollback into a
    /// rescan.
    ///
    /// A peerless `FilterSync` with nothing on disk. Named `offlineSync` rather
    /// than the source suite's `sync` so it does not read as one of the many
    /// `FilterSync` values called `sync` elsewhere in this file.
    private func offlineSync(startHeight: UInt32) throws -> FilterSync {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        return try FilterSync(pool: pool, chain: chain, startHeight: startHeight)
    }

    @Test("the frontier rewinds to the block after the fork")
    func frontierRewinds() async throws {
        let filters = try offlineSync(startHeight: 100)
        try await filters.recordProgressForTest(nextScanHeight: 500)
        try await filters.rollBack(to: 300)
        #expect(await filters.nextScanHeight == 301)
    }

    /// Pinned filter headers above the fork commit to filters for blocks that
    /// are no longer on the chain. Keeping them would make a later cross-check
    /// compare the surviving branch against the orphaned one and reject honest
    /// peers.
    @Test("pinned filter headers above the fork are dropped")
    func pinnedHeadersAboveForkAreDropped() async throws {
        let filters = try offlineSync(startHeight: 100)
        try await filters.recordProgressForTest(
            nextScanHeight: 500,
            filterHeaders: ["200": "aa", "300": "bb", "400": "cc"])

        try await filters.rollBack(to: 300)

        let remaining = await filters.pinnedFilterHeadersForTest
        #expect(remaining.keys.sorted() == ["200", "300"])
        #expect(remaining["400"] == nil, "that block is not on this chain any more")
    }

    /// Same property the wallet has, and for the same reason: the crash marker
    /// names a height, so recovery is a redo.
    @Test("rolling back twice is the same as once")
    func idempotent() async throws {
        let filters = try offlineSync(startHeight: 100)
        try await filters.recordProgressForTest(nextScanHeight: 500,
                                                filterHeaders: ["400": "cc"])
        try await filters.rollBack(to: 300)
        let once = await filters.nextScanHeight
        try await filters.rollBack(to: 300)
        #expect(await filters.nextScanHeight == once)
    }

    /// A fork above the frontier leaves nothing scanned in doubt, and moving
    /// forward here would skip blocks that were never read.
    @Test("the frontier never advances")
    func frontierNeverAdvances() async throws {
        let filters = try offlineSync(startHeight: 100)
        try await filters.recordProgressForTest(nextScanHeight: 200)
        try await filters.rollBack(to: 900)
        #expect(await filters.nextScanHeight == 200)
    }

    // MARK: - Filter matching (BIP158 vectors)

    /// Filter verification + matching against real BIP158 testnet vectors,
    /// exercising CFilterMessage parsing, GCSFilter matching, and the filter
    /// header chain rule FilterSync pins.
    @Test("parsed filters match their block's output scripts")
    func matchRealScripts() throws {
        for vector in try Vectors.bip158(in: .module) {
            let message = CFilterMessage(blockHash: vector.blockHash, filter: vector.filter)
            let parsed = try message.parsedFilter()
            let filter = try GCSFilter(p: GCSFilter.defaultP, m: GCSFilter.defaultM,
                                       key: Data(vector.blockHash.prefix(16)),
                                       n: parsed.n, encoded: parsed.encoded)
            let scripts = vector.block.transactions
                .flatMap { $0.outputs.map(\.scriptPubKey) }
                .filter { !$0.isEmpty && $0.first != 0x6A }
            // Some vector blocks (e.g. height 1414221) carry only OP_RETURN /
            // empty outputs — the basic filter is empty for those by design.
            guard !scripts.isEmpty else {
                #expect(parsed.n == 0, "height \(vector.height)")
                #expect(!filter.containsAny([Data([0x51])]))
                continue
            }
            #expect(filter.containsAny(scripts), "height \(vector.height)")
            for script in Set(scripts) {
                #expect(filter.contains(script), "height \(vector.height)")
            }
            // A foreign script must not match (BIP158 false-positive rate is tiny).
            #expect(!filter.contains(Data([0x51, 0x20] + repeatElement(0x42, count: 32))))
        }
    }

    @Test("filter headers follow the BIP158 chain rule")
    func headerChainRule() throws {
        for vector in try Vectors.bip158(in: .module) {
            // header[h] = SHA256d(SHA256d(filter) || header[h-1]) — the exact
            // check FilterSync performs per cfilter.
            let computed = SHA256d.hash(GCSFilter.filterHash(vector.filter) + vector.previousHeader)
            #expect(computed == vector.header, "height \(vector.height)")
        }
    }

    @Test("cfilter wire round-trip carries the NBytes unchanged")
    func cfilterRoundTrip() throws {
        let vector = try Vectors.bip158(in: .module)[0]
        let message = CFilterMessage(blockHash: vector.blockHash, filter: vector.filter)
        let decoded = try PeerMessage.decode(command: "cfilter", payload: message.serialized)
        #expect(decoded == .cfilter(message))
    }
}
