import Foundation
import Network
import Testing
import TestSupport
@testable import WalletCore

/// FilterSync end to end, by subject: the happy path over a real loopback
/// transport, how a bounded run stops and resumes, what the on-disk progress
/// file may and may not say, which pinned headers survive a batch, how the
/// frontier rewinds under a reorg, and the BIP158 arithmetic underneath it
/// all.
///
/// Merged from `LoopbackTests`, `FilterSyncPersistenceTests`,
/// `FilterProgressRollbackTests` and `FilterMatchingTests`; each `// MARK:`
/// below is one of those suites, in that order, apart from two later
/// sections: the bounded-run and chunked-fetch tests, which sit with the
/// loopback tests they extend, and the pruning section between the second and
/// third, which belongs to neither. The loopback sections open real 127.0.0.1
/// listeners — no external network — and the last two sections touch no
/// socket at all.
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

    /// The read side over a pool that is only relaying: refused, and refused
    /// before the wire. A relay-only pool (`PeerPool.enterRelayOnly(seats:)`)
    /// holds a seat so a signed payment can finish going out; a filter sync
    /// over it would spend that seat on cfcheckpt round trips and could burn
    /// it outright on a peer fault or a stale tip.
    @Test("a relay-only pool refuses a filter sync and asks its peer nothing")
    func relayOnlyRefusesFilterSync() async throws {
        let synthetic = makeSyntheticChain(length: 4, watchHeight: 6)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint])
        await pool.start()
        await pool.enterRelayOnly(seats: 1)

        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  requiredCheckpointPeers: 1)
        await #expect(throws: FilterSyncError.relayOnly) {
            try await sync.sync(watchScripts: []) { _ in }
        }
        #expect(await node.nextMessage(command: "getheaders", timeout: .milliseconds(300)) == nil)
        #expect(await node.nextMessage(command: "getcfcheckpt", timeout: .milliseconds(100)) == nil)
        #expect(await sync.nextScanHeight == 1, "a refused run scans nothing")
        #expect(await pool.connectedPeers().count == 1, "and costs no seat")
        await pool.stop()
    }

    // MARK: - Bounded runs and chunked fetching

    /// `maxBlocks` is what makes a scan that cannot run to the tip possible:
    /// the run stops at its ceiling, saves what it scanned, and the next call
    /// starts from the saved frontier rather than the wallet's start height.
    ///
    /// The ceiling also shortens the batch rather than working around it, so
    /// the cfheaders cross-check still covers exactly the blocks the run
    /// scanned — asserted here on what the node was actually asked.
    @Test("a run with maxBlocks stops at its ceiling and the next resumes from disk")
    func boundedRunStopsAndResumes() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("bounded-progress.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1)
        let collector = MatchCollector()

        try await sync.sync(watchScripts: [synthetic.watchScript], maxBlocks: 2) {
            collector.add($0)
        }
        #expect(await sync.nextScanHeight == 3)
        #expect(collector.matches.isEmpty, "the block that pays us is above this ceiling")

        // The ceiling counts from the frontier, so this run covers 3 ... 4 and
        // finds the payment the first run stopped short of.
        try await sync.sync(watchScripts: [synthetic.watchScript], maxBlocks: 2) {
            collector.add($0)
        }
        #expect(await sync.nextScanHeight == 5)
        #expect(collector.matches.map(\.height) == [synthetic.watchHeight])

        // Each run asked for cfheaders over exactly the blocks it scanned:
        // a shorter batch, not a batch skipped.
        let cfheaderRanges = await node.receivedMessages.compactMap { message -> UInt32? in
            guard case let .getcfheaders(request) = message else { return nil }
            return request.startHeight
        }
        #expect(cfheaderRanges == [1, 3])

        // A fresh instance reads the bounded frontier, and an unbounded run
        // from there finishes the chain.
        let reloaded = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                      storageURL: progressFile, requiredCheckpointPeers: 1)
        #expect(await reloaded.nextScanHeight == 5)
        try await reloaded.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }
        #expect(await reloaded.nextScanHeight == 7)
        #expect(collector.matches.map(\.height) == [synthetic.watchHeight])
    }

    /// The other end of `maxBlocks`: a run that may scan nothing. The ceiling
    /// is resolved before the cfcheckpt round trip, so a caller handing back
    /// control with no room left spends no round trips at all and leaves the
    /// frontier exactly where it was — the state the next run resumes from.
    @Test("a run bounded to zero blocks asks for nothing and moves nothing")
    func zeroMaxBlocksScansNothing() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("zero-bounded-progress.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1)
        let collector = MatchCollector()

        try await sync.sync(watchScripts: [synthetic.watchScript], maxBlocks: 0) {
            collector.add($0)
        }
        #expect(await sync.nextScanHeight == 1, "the frontier stands where it was")
        #expect(collector.matches.isEmpty)
        #expect(await sync.pinnedFilterHeadersForTest.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: progressFile.path),
                "a run that scanned nothing has nothing to persist")

        // Nothing was asked of the peer beyond the header sync — not even the
        // checkpoint comparison, which is one round trip per peer.
        let asked = await node.receivedMessages.filter { message in
            switch message {
            case .getcfcheckpt, .getcfheaders, .getcfilters: true
            default: false
            }
        }
        #expect(asked.isEmpty)

        // And the run that follows it is unaffected: the ceiling bounds one
        // run, it does not disable the sync.
        try await sync.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }
        #expect(await sync.nextScanHeight == 7)
        #expect(collector.matches.map(\.height) == [synthetic.watchHeight])
    }

    /// A chunk size of zero would make each chunk's stop one below its start,
    /// so the loop would never advance and a scan would hang rather than fail;
    /// one above the batch length would ask a peer for filters past the batch
    /// its headers were pinned over. Neither is a caller's to get wrong, which
    /// is what the clamp is for.
    @Test("the chunk size is clamped to a range a batch can be fetched in")
    func chunkSizeIsClamped() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        func chunk(_ requested: UInt32) async throws -> UInt32 {
            try await FilterSync(pool: pool, chain: chain, startHeight: 1,
                                 filtersPerChunk: requested).filtersPerChunk
        }
        #expect(try await chunk(0) == 1, "zero would never advance the chunk loop")
        #expect(try await chunk(1) == 1)
        #expect(try await chunk(100) == 100)
        #expect(try await chunk(FilterSync.maxRangePerRequest) == FilterSync.maxRangePerRequest)
        #expect(try await chunk(FilterSync.maxRangePerRequest + 1)
            == FilterSync.maxRangePerRequest)
        #expect(try await chunk(.max) == FilterSync.maxRangePerRequest)
        // The default a caller who says nothing gets.
        let standard = try FilterSync(pool: pool, chain: chain, startHeight: 1)
        #expect(await standard.filtersPerChunk == FilterSync.defaultFiltersPerChunk)
    }

    /// Chunking changes how the filters are fetched and nothing else, so the
    /// two paths have to agree on everything outside FilterSync: the same
    /// matches, and the same saved progress. What differs is what the scan
    /// holds while it works.
    @Test("a chunked scan and a whole-batch scan agree, and the chunked one holds less")
    func chunkedScanMatchesWholeBatch() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let whole = try await scanWholeChain(synthetic, filtersPerChunk: 1_000)
        let chunked = try await scanWholeChain(synthetic, filtersPerChunk: 2)

        #expect(whole.matches.map(\.height) == chunked.matches.map(\.height))
        #expect(whole.matches.map(\.blockHash) == chunked.matches.map(\.blockHash))
        #expect(whole.matches.count == 1)
        #expect(whole.progress == chunked.progress)

        // One request for the whole batch, against one per chunk: 1 ... 2,
        // 3 ... 4, 5 ... 6. The stop hashes say the ranges are real.
        #expect(whole.filterRequests.map(\.startHeight) == [1])
        #expect(chunked.filterRequests.map(\.startHeight) == [1, 3, 5])
        #expect(chunked.filterRequests.map(\.stopHash)
            == [2, 4, 6].map { synthetic.blocks[$0].hash })

        // The point of the chunks: peak buffered filter bytes follow the chunk
        // size, not the batch length. Two filters of six, on a fixture whose
        // blocks are all about the same size, is comfortably under half.
        #expect(chunked.peakChunkBytes > 0)
        #expect(chunked.peakChunkBytes * 2 <= whole.peakChunkBytes)
    }

    /// A chunk size that does not divide the batch, which is the ordinary case
    /// on a real chain and the one the fixture above cannot reach: 6 blocks in
    /// chunks of 2 is three whole chunks, so the `min(chunkStart + chunk - 1,
    /// batchStop)` never takes its `batchStop` branch and the ragged last chunk
    /// is unpinned by any assertion. Seven blocks in chunks of four take it:
    /// 1 ... 4 is a whole chunk and 5 ... 7 is what is left, which the stop
    /// hashes name. A chunk that ran past the batch would ask this node about a
    /// block it does not have.
    @Test("a chunk that does not divide the batch ends on the batch stop")
    func raggedFinalChunkStopsAtTheBatch() async throws {
        let synthetic = makeSyntheticChain(length: 7, watchHeight: 6)
        let ragged = try await scanWholeChain(synthetic, filtersPerChunk: 4)

        #expect(ragged.filterRequests.map(\.startHeight) == [1, 5])
        #expect(ragged.filterRequests.map(\.stopHash)
            == [4, 7].map { synthetic.blocks[$0].hash })
        #expect(ragged.matches.map(\.height) == [6])
        #expect(ragged.progress.nextScanHeight == 8)
    }

    /// The chunk bounds messages; this bounds bytes. Nothing in a chunk is
    /// looked at until all of it has arrived, so the message count alone caps
    /// a hostile burst at `count` times the protocol maximum — 400 MB at the
    /// default chunk size — before the first filter is checked.
    ///
    /// Asserted at the transport, where the bound lives: an honest burst of
    /// the same three filters passes under a generous bound, and the same
    /// request under a bound of one byte fails on the first message with a
    /// protocol violation rather than sitting there until the timeout.
    @Test("requestMany refuses a burst past its byte bound and drops the peer")
    func requestManyBoundsTheBurstInBytes() async throws {
        let synthetic = makeSyntheticChain(length: 3, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: synthetic.params)
        try await peer.connect()
        let request = PeerMessage.getcfilters(
            GetCFiltersRequest(startHeight: 1, stopHash: synthetic.blocks[3].hash))

        // Honest first, so the failure below cannot be the node refusing to
        // serve: three filters, well under a bound a real chunk would use.
        let honest = try await peer.requestMany(request, expecting: "cfilter", count: 3,
                                                maxTotalBytes: FilterSync.chunkByteBound(filters: 3),
                                                timeout: .seconds(30))
        #expect(honest.count == 3)

        var thrown: (any Error)?
        do {
            _ = try await peer.requestMany(request, expecting: "cfilter", count: 3,
                                           maxTotalBytes: 1, timeout: .seconds(30))
        } catch {
            thrown = error
        }
        guard case let .protocolViolation(reason)? = thrown as? PeerError else {
            Issue.record("expected a protocol violation, got \(String(describing: thrown))")
            return
        }
        #expect(reason.contains("cfilter burst"))
        // Torn down, not merely failed: the burst it was still sending must
        // not go on filling memory after the request that bounded it is gone.
        #expect(await !peer.isConnected)
    }

    /// The same bound one layer up, where a scan meets it: a peer answering
    /// the chunk it was asked for, in the right count and the right shape,
    /// with messages far larger than a filter can be.
    ///
    /// The padding keeps the commitments honest, so nothing the client
    /// computes for itself contradicts this peer — the filters it sends would
    /// fail their header check, but that check runs after the whole chunk has
    /// arrived, which is precisely what the byte bound has to beat. Two
    /// filters of 2 MB against a bound of two times
    /// `maxFilterMessageBytes` means the second message crosses it and the
    /// chunk never completes.
    @Test("a peer whose filter chunk is too large is refused mid-burst and dropped for the session")
    func oversizedFilterChunkIsRefused() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        // An honest node on the same chain and the same chunk size still
        // scans it end to end: the bound refuses size, not chunking.
        let honest = try await scanWholeChain(synthetic, filtersPerChunk: 2)
        #expect(honest.progress.nextScanHeight == 7)
        #expect(honest.matches.map(\.height) == [3])

        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                oversizedFilterBytes: 2_000_000)
        try await node.start()
        defer { Task { await node.stop() } }
        let endpoint = await node.endpoint
        let pool = PeerPool(params: synthetic.params, peerCount: 1, manualPeers: [endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("oversized-progress.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1,
                                  filtersPerChunk: 2)

        var thrown: (any Error)?
        do {
            try await sync.sync(watchScripts: [synthetic.watchScript]) { _ in }
        } catch {
            thrown = error
        }
        guard case let .protocolViolation(reason)? = thrown as? PeerError else {
            Issue.record("expected a protocol violation, got \(String(describing: thrown))")
            return
        }
        #expect(reason.contains("cfilter burst"))

        // Judged as a data fault, like a filter that does not reproduce its
        // header: dropped for the session rather than cooled off.
        #expect(await pool.connectedPeers().isEmpty)
        #expect(await pool.rejectionReason(endpoint)?.contains("cfilter burst") == true)
        #expect(await pool.coolingEndpoints.isEmpty)

        // And the batch changed nothing: no frontier moved, nothing was saved.
        #expect(await sync.nextScanHeight == 1)
        #expect(!FileManager.default.fileExists(atPath: progressFile.path))
    }

    /// Being an actor bounds what runs *at once*, not what interleaves: every
    /// step of `sync` awaits the network or the caller's `onMatch`, and a
    /// second call is free to run during those suspensions. Both passes then
    /// share one pool and one progress record, and a peer's reply goes to
    /// whichever collector expects the command first.
    ///
    /// The first run is parked inside `onMatch` — one of exactly those
    /// suspensions — so the second call lands in the window that used to
    /// interleave. It has to be refused there and then, having done nothing,
    /// and the run it collided with has to finish as though it had never
    /// happened: the same matches and the same saved progress a single pass
    /// over this chain leaves.
    @Test("a second sync during the first is refused, and the first is untouched")
    func concurrentSyncIsRefused() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let expected = try await scanWholeChain(synthetic, filtersPerChunk: 2)

        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("concurrent-progress.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1,
                                  filtersPerChunk: 2)

        let gate = SyncGate()
        let collector = MatchCollector()
        let watchScript = synthetic.watchScript
        let first = Task { () -> Result<Void, any Error> in
            let outcome: Result<Void, any Error>
            do {
                try await sync.sync(watchScripts: [watchScript]) { match in
                    collector.add(match)
                    await gate.reachMatch()
                    await gate.waitForRelease()
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            // A run that ended without ever matching opens the gate too, so a
            // broken first pass fails this test on an assertion instead of
            // parking it on a wait that will never be resumed.
            await gate.reachMatch()
            return outcome
        }
        await gate.waitForMatch()

        var thrown: (any Error)?
        do {
            try await sync.sync(watchScripts: [synthetic.watchScript]) { _ in
                Issue.record("the refused sync must not scan anything")
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? FilterSyncError == .syncAlreadyRunning)
        // Refused before any side effect: the frontier is still where the
        // first run left it, mid-batch and unsaved.
        #expect(await sync.nextScanHeight == 1)
        #expect(!FileManager.default.fileExists(atPath: progressFile.path))

        await gate.release()
        try await first.value.get()
        #expect(collector.matches.map(\.height) == expected.matches.map(\.height))
        #expect(await sync.nextScanHeight == 7)
        let saved = try JSONDecoder().decode(FilterSync.Progress.self,
                                             from: Data(contentsOf: progressFile))
        #expect(saved == expected.progress)

        // And the flag is cleared on the way out, so the next scan runs.
        try await sync.sync(watchScripts: [synthetic.watchScript]) { _ in }
    }

    @Test("the scan ceiling counts from the frontier, stops at the tip, and never traps")
    func scanCeilingArithmetic() {
        #expect(FilterSync.scanCeiling(frontier: 100, maxBlocks: 10, tip: 1_000) == 109)
        #expect(FilterSync.scanCeiling(frontier: 100, maxBlocks: 1, tip: 1_000) == 100)
        #expect(FilterSync.scanCeiling(frontier: 100, maxBlocks: 10_000, tip: 1_000) == 1_000)
        #expect(FilterSync.scanCeiling(frontier: 100, maxBlocks: nil, tip: 1_000) == 1_000)
        // No room means no blocks, which is not the same as no ceiling.
        #expect(FilterSync.scanCeiling(frontier: 100, maxBlocks: 0, tip: 1_000) == nil)
        // "As far as you can get" must not overflow the addition.
        #expect(FilterSync.scanCeiling(frontier: .max - 1, maxBlocks: .max, tip: .max) == .max)
    }

    /// What one scan of the whole synthetic chain did, over its own loopback
    /// node so two chunk sizes can be compared without either seeing the
    /// other's connection.
    private struct ScanOutcome {
        let matches: [BlockMatch]
        let progress: FilterSync.Progress
        let peakChunkBytes: Int
        let filterRequests: [GetCFiltersRequest]
    }

    private func scanWholeChain(_ synthetic: SyntheticChain,
                                filtersPerChunk: UInt32) async throws -> ScanOutcome {
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let progressFile = tempFileURL("chunked-progress.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: progressFile, requiredCheckpointPeers: 1,
                                  filtersPerChunk: filtersPerChunk)
        let collector = MatchCollector()
        try await sync.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }
        let saved = try JSONDecoder().decode(FilterSync.Progress.self,
                                             from: Data(contentsOf: progressFile))
        let requests = await node.receivedMessages.compactMap { message -> GetCFiltersRequest? in
            guard case let .getcfilters(request) = message else { return nil }
            return request
        }
        return ScanOutcome(matches: collector.matches, progress: saved,
                           peakChunkBytes: await sync.peakChunkFilterBytesForTest,
                           filterRequests: requests)
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

    // MARK: - Pinned header pruning

    /// The store used to keep one pinned header per block scanned, rewritten
    /// whole after every batch, so a wallet with an old birthday carried tens
    /// of megabytes of them and re-encoded that on each of a thousand batches.
    /// A batch now persists only what a later check can still ask for.
    ///
    /// These cases are about what survives — and, more importantly, about the
    /// checks that must still be able to run afterwards, because a header that
    /// is not pinned is not compared, and a prune that dropped one would retire
    /// a comparison without ever failing a test.
    ///
    /// The fixture below is one pinned header per height: the shape the store
    /// had before pruning.
    private func pinsForEveryHeight(in range: ClosedRange<UInt32>) -> [String: String] {
        var headers: [String: String] = [:]
        for height in range {
            headers[String(height)] = Data(repeating: UInt8(height % 251), count: 32).hex
        }
        return headers
    }

    @Test("a prune keeps every checkpoint boundary, the anchor, and the recent run")
    func pruneKeepsBoundariesAnchorAndRecentRun() {
        let dense = pinsForEveryHeight(in: 1 ... 5_432)
        let pruned = FilterSync.prunedFilterHeaders(dense, frontier: 5_433)

        // The anchor: what the next batch checks a peer's announced chain
        // against.
        #expect(pruned["5432"] == dense["5432"])
        // Every boundary a cfcheckpt reply names, down to the oldest — these
        // are compared on every sync and cost one header per 1,000 blocks.
        for boundary in stride(from: 1_000, through: 5_000, by: 1_000) {
            #expect(pruned[String(boundary)] == dense[String(boundary)], "boundary \(boundary)")
        }
        // The recent run reaches back to the boundary below the last one, so a
        // reorg rewinding into it still lands on a pinned anchor.
        #expect(pruned["4000"] != nil)
        #expect(pruned["3999"] == nil)
        #expect(pruned["1500"] == nil)
        // 4,000 through 5,432 is 1,433 headers; the boundaries at 1,000, 2,000
        // and 3,000 are the only older ones kept.
        #expect(pruned.count == 1_436)
    }

    @Test("a prune refuses when the frontier anchor is not pinned")
    func pruneRefusesWithoutAnchor() {
        var dense = pinsForEveryHeight(in: 1 ... 5_432)
        dense["5432"] = nil

        // Fail closed: a store that has already lost its anchor is not one to
        // prune further, because the pruning would be reasoning about a chain
        // it cannot verify it has.
        #expect(FilterSync.prunedFilterHeaders(dense, frontier: 5_433) == dense)
        // And a frontier of zero has no anchor to speak of.
        #expect(FilterSync.prunedFilterHeaders(dense, frontier: 0) == dense)
    }

    /// Below the first checkpoint boundary there is no boundary to keep and no
    /// older interval to reach back to, so the kept run starts at zero and the
    /// prune is a no-op. A wallet in its first thousand blocks must not be
    /// pruned down to its anchor: everything it has is inside the range a
    /// reorg could rewind into.
    @Test("a frontier below the first boundary keeps every header it has")
    func pruneBelowTheFirstBoundaryKeepsEverything() {
        let dense = pinsForEveryHeight(in: 1 ... 499)
        #expect(FilterSync.prunedFilterHeaders(dense, frontier: 500) == dense)

        // And one block past the first boundary, where `keepFrom` reaches back
        // an interval and lands on zero rather than underflowing it.
        let acrossTheFirst = pinsForEveryHeight(in: 1 ... 1_000)
        #expect(FilterSync.prunedFilterHeaders(acrossTheFirst, frontier: 1_001)
            == acrossTheFirst)
    }

    /// The store is a `[String: String]` on disk, so its keys are whatever a
    /// file says they are. A key that is not a height cannot be compared
    /// against a checkpoint, cannot anchor a batch, and cannot be rewound
    /// into by a reorg — keeping it would grow the file forever with entries
    /// no check can ever read.
    @Test("a prune drops a stored key that is not a height")
    func pruneDropsKeysThatAreNotHeights() {
        var dense = pinsForEveryHeight(in: 1 ... 5_432)
        dense["not-a-height"] = Data(repeating: 0xAB, count: 32).hex
        dense["-1"] = Data(repeating: 0xCD, count: 32).hex
        dense["99999999999999999999"] = Data(repeating: 0xEF, count: 32).hex

        let pruned = FilterSync.prunedFilterHeaders(dense, frontier: 5_433)
        #expect(pruned["not-a-height"] == nil)
        #expect(pruned["-1"] == nil)
        #expect(pruned["99999999999999999999"] == nil)
        // The real headers are kept exactly as the case above says they are,
        // so the junk was dropped rather than the prune refused.
        #expect(pruned == FilterSync.prunedFilterHeaders(pinsForEveryHeight(in: 1 ... 5_432),
                                                          frontier: 5_433))
    }

    @Test("batch after batch, the kept headers stay contiguous and bounded")
    func pruneAcrossBatchesStaysContiguous() {
        // What the batch loop does: pin a batch on top of what was kept, then
        // prune to the new frontier. Nine batches, so the frontier is well past
        // the point where the first ones would have been dropped.
        var kept: [String: String] = [:]
        var frontier: UInt32 = 1
        for _ in 0 ..< 9 {
            let batchStop = frontier + FilterSync.maxRangePerRequest - 1
            kept.merge(pinsForEveryHeight(in: frontier ... batchStop)) { _, new in new }
            frontier = batchStop + 1
            kept = FilterSync.prunedFilterHeaders(kept, frontier: frontier)
        }

        #expect(frontier == 9_001)
        // Contiguous from the boundary below the last one up to the anchor:
        // the range a rollback can rewind into has no holes in it.
        for height in UInt32(8_000) ... 9_000 {
            #expect(kept[String(height)] != nil, "height \(height)")
        }
        #expect(kept["7999"] == nil)
        // Every older boundary is still there, and nothing else is: 8,000
        // through 9,000 plus the boundaries at 1,000 to 7,000.
        for boundary in stride(from: 1_000, through: 7_000, by: 1_000) {
            #expect(kept[String(boundary)] != nil, "boundary \(boundary)")
        }
        #expect(kept.count == 1_001 + 7)
    }

    /// A wallet starting at 999, synced over `progressFile` against a node
    /// holding the chain up to `nodeTip`. Returns the match count, so a case
    /// can prove the scan really ran rather than exiting early.
    ///
    /// 999 rather than 1 because pruning only has something to drop once the
    /// frontier is past its second checkpoint boundary — below that the kept
    /// run covers everything — and starting just under the first boundary gets
    /// there while scanning about a thousand blocks.
    @discardableResult
    private func syncFrom999(_ synthetic: SyntheticChain, nodeTip: Int,
                             progressFile: URL) async throws -> Int {
        let node = LoopbackNode(params: synthetic.params,
                                chain: Array(synthetic.blocks.prefix(nodeTip + 1)))
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 999,
                                  storageURL: progressFile, requiredCheckpointPeers: 1)

        let collector = MatchCollector()
        try await sync.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }

        #expect(await sync.nextScanHeight == UInt32(nodeTip) + 1)
        return collector.matches.count
    }

    /// A peerless sync over an existing progress file, for reading what a
    /// completed sync left on disk — and for proving the pruned file is one
    /// `load` still accepts.
    private func reload(_ progressFile: URL, params: NetworkParams) throws -> FilterSync {
        let pool = PeerPool(params: params, peerCount: 0, manualPeers: [])
        return try FilterSync(pool: pool, chain: try HeaderChain(params: params),
                              startHeight: 999, storageURL: progressFile)
    }

    @Test("a sync past two boundaries persists the boundaries and the anchor, and drops the rest")
    func syncPrunesPersistedProgress() async throws {
        let synthetic = makeSyntheticChain(length: 2_100, watchHeight: 1_500)
        let progressFile = tempFileURL("filter-prune.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        let matches = try await syncFrom999(synthetic, nodeTip: 2_001, progressFile: progressFile)
        #expect(matches == 1, "the scan really ran")

        let reloaded = try reload(progressFile, params: synthetic.params)
        #expect(reloaded.persistenceState == .loaded)
        #expect(await reloaded.nextScanHeight == 2_002)
        #expect(await reloaded.filterHeader(at: 2_001) != nil, "the anchor")
        #expect(await reloaded.filterHeader(at: 2_000) != nil, "a boundary")
        #expect(await reloaded.filterHeader(at: 1_000) != nil, "the oldest boundary")
        #expect(await reloaded.filterHeader(at: 999) == nil)
        #expect(await reloaded.filterHeader(at: 998) == nil, "the bootstrap anchor is spent")
        // 1,000 through 2,001, and nothing else.
        #expect(await reloaded.pinnedFilterHeadersForTest.count == 1_002)
    }

    /// The upgrade case: a file written by a build that kept one header per
    /// block scanned is read in the shape it was written, and the next batch
    /// prunes it rather than carrying it forward for the rest of the wallet's
    /// life. Nothing migrates the file on load, and nothing has to: the batch
    /// that persists is the batch that prunes.
    @Test("a progress file written before pruning is pruned by the next batch")
    func denseProgressFileIsPrunedByTheNextBatch() async throws {
        let synthetic = makeSyntheticChain(length: 2_100, watchHeight: 1_500)
        let progressFile = tempFileURL("filter-prune-dense.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }

        // One batch, ending below the second boundary: what the store looked
        // like before pruning existed — a header per height, none dropped.
        try await syncFrom999(synthetic, nodeTip: 1_998, progressFile: progressFile)
        let dense = try await reload(progressFile, params: synthetic.params)
            .pinnedFilterHeadersForTest
        #expect(dense.count == 1_001, "998 through 1,998")
        #expect(dense["998"] != nil)
        #expect(dense["999"] != nil)

        // One more batch over that file, and it comes back pruned.
        try await syncFrom999(synthetic, nodeTip: 2_001, progressFile: progressFile)
        let pruned = try reload(progressFile, params: synthetic.params)
        #expect(await pruned.pinnedFilterHeadersForTest.count == 1_002)
        #expect(await pruned.filterHeader(at: 998) == nil)
        #expect(await pruned.filterHeader(at: 1_000) != nil, "the boundary survives the upgrade")
        #expect(await pruned.filterHeader(at: 2_001) != nil, "so does the anchor")
    }

    @Test("a sync resumed over a pruned store makes the same checkpoint comparison")
    func resumedSyncComparesAgainstKeptBoundaries() async throws {
        let synthetic = makeSyntheticChain(length: 2_100, watchHeight: 1_500)
        let progressFile = tempFileURL("filter-prune-resume.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        try await syncFrom999(synthetic, nodeTip: 2_001, progressFile: progressFile)

        // A node with 100 more blocks, because a sync already at the tip
        // returns before the checkpoint comparison runs at all.
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let resumed = try FilterSync(pool: pool, chain: try HeaderChain(params: synthetic.params),
                                     startHeight: 999, storageURL: progressFile,
                                     requiredCheckpointPeers: 1)

        try await resumed.sync(watchScripts: []) { _ in }

        // The kept anchor carried the batch, and the kept boundaries matched
        // the node's cfcheckpt: 1,000 in `checkPinnedBoundaries` before the
        // batches, and 2,000 in the final guard after them — the highest
        // boundary at or below the tip, which is the entry Core's cfcheckpt
        // list ends on.
        #expect(await resumed.nextScanHeight == 2_101)
        #expect(await resumed.filterHeader(at: 2_100) != nil)
        #expect(await resumed.filterHeader(at: 1_000) != nil)
        #expect(await resumed.filterHeader(at: 2_000) != nil)
    }

    @Test("a peer lying about the filter chain is still caught at the oldest kept boundary")
    func prunedStoreStillCatchesALiar() async throws {
        let synthetic = makeSyntheticChain(length: 2_100, watchHeight: 1_500)
        let progressFile = tempFileURL("filter-prune-liar.json")
        defer { try? FileManager.default.removeItem(at: progressFile.deletingLastPathComponent()) }
        try await syncFrom999(synthetic, nodeTip: 2_001, progressFile: progressFile)

        // Same chain, a complete and self-consistent lie about its filter
        // commitments — catchable only against something already pinned.
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                lieAboutFilterCommitments: true, lieSalt: 0xFF)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()
        defer { Task { await pool.stop() } }
        let resumed = try FilterSync(pool: pool, chain: try HeaderChain(params: synthetic.params),
                                     startHeight: 999, storageURL: progressFile,
                                     requiredCheckpointPeers: 1)

        var thrown: (any Error)?
        do {
            try await resumed.sync(watchScripts: []) { _ in }
        } catch {
            thrown = error
        }

        guard case let .checkpointMismatch(reason)? = thrown as? FilterSyncError else {
            Issue.record("expected checkpointMismatch, got \(String(describing: thrown))")
            return
        }
        // Height 1,000 is the oldest height the prune kept — at frontier
        // 2,002 it is `keepFrom` itself, not a boundary below it — and it is
        // the one a keep-the-last-N prune would have dropped, taking this
        // refusal with it. A boundary strictly below the kept run is covered
        // purely, by "batch after batch, the kept headers stay contiguous and
        // bounded".
        #expect(reason.contains("pinned header at 1000"))
        #expect(await resumed.nextScanHeight == 2_002, "nothing advanced")
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

    /// A rollback into a pruned store, which is the case pruning has to answer
    /// for: the frontier rewinds, the orphaned pins go, and the fork height is
    /// still pinned, so the next batch checks the peer's announced chain
    /// against ours instead of adopting it. Keeping the recent run is what
    /// buys that.
    @Test("a reorg into the kept run still rolls back to an anchored frontier")
    func rollBackAfterPrune() async throws {
        let filters = try offlineSync(startHeight: 1)
        let kept = FilterSync.prunedFilterHeaders(pinsForEveryHeight(in: 1 ... 5_432),
                                                  frontier: 5_433)
        try await filters.recordProgressForTest(nextScanHeight: 5_433, filterHeaders: kept)

        try await filters.rollBack(to: 5_400)

        #expect(await filters.nextScanHeight == 5_401)
        #expect(await filters.filterHeader(at: 5_400) != nil, "the new frontier's anchor")
        #expect(await filters.filterHeader(at: 5_401) == nil, "that block is not on this chain any more")
        // The comparisons below the fork are untouched by either step.
        #expect(await filters.filterHeader(at: 5_000) != nil)
        #expect(await filters.filterHeader(at: 1_000) != nil)
    }

    /// The honest residual, stated as a test rather than left to be found. A
    /// reorg deeper than the kept run lands on a height whose header was
    /// pruned, so the next sync re-anchors on the peer's announced header
    /// exactly as a fresh install does. The boundaries are why that is bounded
    /// rather than open: the fabricated chain is compared against a pinned
    /// boundary within the next thousand blocks.
    @Test("a reorg below the kept run re-anchors like a fresh install, boundaries intact")
    func rollBackBelowKeptRun() async throws {
        let filters = try offlineSync(startHeight: 1)
        let kept = FilterSync.prunedFilterHeaders(pinsForEveryHeight(in: 1 ... 5_432),
                                                  frontier: 5_433)
        try await filters.recordProgressForTest(nextScanHeight: 5_433, filterHeaders: kept)

        try await filters.rollBack(to: 3_500)

        #expect(await filters.nextScanHeight == 3_501)
        #expect(await filters.filterHeader(at: 3_500) == nil)
        #expect(await filters.filterHeader(at: 3_000) != nil, "the boundary that still compares")
        #expect(await filters.filterHeader(at: 1_000) != nil)
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

/// Parks a sync inside its `onMatch` until the test lets it go, so a second
/// call can be made while the first is genuinely suspended mid-run. Polling
/// for that window would make the test a race; this makes it an ordering.
private actor SyncGate {
    private var matched = false
    private var matchWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    /// Called from `onMatch`: the run has reached the parking spot.
    func reachMatch() {
        matched = true
        matchWaiter?.resume()
        matchWaiter = nil
    }

    func waitForMatch() async {
        guard !matched else { return }
        await withCheckedContinuation { matchWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
}
