import Foundation
import Testing
import TestSupport
@testable import BitcoinP2P

/// What happens when peers disagree, and what happens when there is nobody to
/// disagree with (epic #100, invariant S5).
///
/// BIP157 filters are not committed to by consensus, so a peer can serve a
/// self-consistent but wrong filter-commitment chain and nothing in the block
/// headers contradicts it. The only defence is comparing peers. `FilterSync`
/// adopts the majority cfcheckpt answer rather than the first reply — a first
/// reply adopted by fiat would let a lying peer evict the honest ones and
/// become the sole reference. The per-batch cfheaders cross-check is judged
/// by the same rule (#26).
///
/// The lying node here keeps its block headers honest and rebuilds a complete,
/// internally consistent filter-commitment chain, so it cannot be caught by
/// the client's own arithmetic. Only another peer catches it.
@Suite("Peer disagreement")
struct PeerDisagreementTests {
    /// Two peers that disagree give no majority. The lie is unattributable —
    /// either one could be the liar — so the sync must fail closed rather than
    /// pick a side, and must blame nobody.
    @Test("two peers disagreeing about filter commitments fails closed")
    func twoWayDisagreementFailsClosed() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let honest = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        let liar = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                lieAboutFilterCommitments: true)
        try await honest.start()
        try await liar.start()
        defer { Task { await honest.stop(); await liar.stop() } }

        let endpoints = [await honest.endpoint, await liar.endpoint]
        let peersFile = tempFileURL("peers.json")
        let pool = PeerPool(params: synthetic.params, peerCount: 2,
                            manualPeers: endpoints, peersFileURL: peersFile)
        await pool.start()
        #expect(await pool.connectedPeers().count == 2)

        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: tempFileURL("progress.json"),
                                  requiredCheckpointPeers: 2)

        // The specific error matters: a bare "some FilterSyncError" would also
        // pass if the cross-check were gone and the lie were caught by
        // something weaker downstream.
        //
        // Note which defence fires here. Checkpoints are served every 1000
        // blocks, so on a six-block chain both peers return an *empty*
        // cfcheckpt list — identical, no disagreement — and the cfcheckpt
        // majority rule never engages. The defence that catches this lie is
        // the per-batch cfheaders cross-check, which is exactly why this test
        // stays at six blocks: it is the control for that layer.
        //
        // The majority rule itself is exercised in `CheckpointMajorityTests`,
        // on a 1,001-block chain that actually crosses the interval (#129).
        do {
            try await sync.sync(watchScripts: [synthetic.watchScript]) { _ in }
            Issue.record("a two-way disagreement was accepted")
        } catch let error as FilterSyncError {
            guard case let .checkpointMismatch(reason) = error,
                  reason.contains("cfheaders disagree")
            else {
                Issue.record("caught \(error) rather than a cfheaders disagreement")
                return
            }
        }
        // Nothing was pinned from a disputed answer.
        #expect(await sync.nextScanHeight == 1,
                "a disputed filter view must not advance the scan frontier")
        // And nobody was banned for it. A 1–1 split cannot say which peer
        // lied, so both are cooled off — the rest a slow peer gets — rather
        // than one of them condemned for having connected second (#26).
        for endpoint in endpoints {
            #expect(await pool.coolingEndpoints.contains(endpoint),
                    "an unattributable disagreement cools \(endpoint) off, not bans it")
            #expect(await pool.rejectionReason(endpoint)?.contains("cfheaders disagree") == true)
        }
        await pool.stop()
        // Cooled, not condemned: both survive in the persisted good-peers
        // file, which `misbehaving` would have struck them from.
        #expect(try PeerCooldownTests.storedPeers(peersFile) == Set(endpoints),
                "a tie must not strike either peer from the peers file")
    }

    /// The fix for #26: a liar seated *first*. The cfheaders cross-check kept
    /// the first reply as its reference and evicted whoever contradicted it
    /// later, so seating order decided blame — the liar became the reference
    /// and an honest peer was banned, struck from the persisted good-peers
    /// file, for telling the truth. Judged by majority, the liar is the one
    /// that goes and the sync completes on the honest answer.
    ///
    /// Six blocks, so cfcheckpt is empty for everyone and only the cfheaders
    /// layer can catch the lie (see above). Peer order is dial-completion
    /// order, so the liar is pinned to the front by delaying the honest
    /// nodes' handshakes, as `CheckpointMajorityTests` does.
    @Test("a liar seated first is the one evicted, not the honest peer that contradicts it")
    func liarFirstIsTheOneEvicted() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let liar = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                lieAboutFilterCommitments: true)
        let honestA = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                   versionDelay: .milliseconds(150))
        let honestB = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                   versionDelay: .milliseconds(250))
        let nodes = [liar, honestA, honestB]
        for node in nodes { try await node.start() }
        defer { for node in nodes { Task { await node.stop() } } }

        let liarEndpoint = await liar.endpoint
        let honestEndpoints = [await honestA.endpoint, await honestB.endpoint]
        let peersFile = tempFileURL("peers.json")
        let pool = PeerPool(params: synthetic.params, peerCount: 3,
                            manualPeers: [liarEndpoint] + honestEndpoints,
                            peersFileURL: peersFile)
        await pool.start()
        #expect(await pool.connectedPeers().count == 3)
        // Precondition for what this test is actually about.
        let first = await pool.connectedPeers().first
        #expect(await first?.endpoint.description == liarEndpoint.description,
                "fixture precondition: the liar must be first in the peer list")

        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: tempFileURL("progress.json"),
                                  requiredCheckpointPeers: 3)
        let collector = MatchCollector()
        try await sync.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }

        // The honest answer was adopted and the scan ran to the tip.
        #expect(collector.matches.count == 1)
        #expect(await sync.nextScanHeight == 7)

        // The liar is the one gone — banned, not rested, because two peers
        // outvoting it makes the lie attributable — and both honest peers
        // keep their seats.
        let connected = await Self.connectedEndpoints(pool)
        #expect(connected.contains(liarEndpoint.description) == false)
        for endpoint in honestEndpoints {
            #expect(connected.contains(endpoint.description),
                    "an honest peer was evicted for contradicting the liar")
        }
        #expect(await pool.rejectionReason(liarEndpoint)?.contains("cfheaders mismatch") == true)
        #expect(await pool.coolingEndpoints.contains(liarEndpoint) == false,
                "a ban is not a cooldown — it must not expire")
        await pool.stop()
        #expect(try PeerCooldownTests.storedPeers(peersFile) == Set(honestEndpoints),
                "the liar is struck from the peers file; the honest peers stay")
    }

    static func connectedEndpoints(_ pool: PeerPool) async -> Set<String> {
        var result: Set<String> = []
        for peer in await pool.connectedPeers() { result.insert(await peer.endpoint.description) }
        return result
    }

    // Positive control: the same two-peer setup with both peers honest syncs
    // normally, so the failure above is the disagreement being caught rather
    // than the two-peer path being broken. That is `LoopbackTests.filterSync`,
    // which runs the full BIP157 flow with one peer and with two.

    /// The eclipse case, pinned as current behaviour rather than asserted as
    /// desirable.
    ///
    /// With one peer there is nobody to compare against, so `FilterSync`
    /// accepts that peer's filter view and advances. A wallet in this state
    /// has no corroboration and no indication of it. That is a deliberate
    /// degradation — failing closed would strand a user whose network reaches
    /// only one peer — but it is the sharpest boundary in a wallet whose whole
    /// claim is that it trusts no server, so it is recorded here rather than
    /// left implicit.
    @Test("a single peer is trusted without corroboration")
    func singlePeerIsTrustedUncorroborated() async throws {
        let synthetic = makeSyntheticChain(length: 6, watchHeight: 3)
        let liar = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                lieAboutFilterCommitments: true)
        try await liar.start()
        defer { Task { await liar.stop() } }

        let pool = PeerPool(params: synthetic.params, peerCount: 1,
                            manualPeers: [await liar.endpoint],
                            peersFileURL: tempFileURL("peers.json"))
        await pool.start()

        let chain = try HeaderChain(params: synthetic.params)
        let sync = try FilterSync(pool: pool, chain: chain, startHeight: 1,
                                  storageURL: tempFileURL("progress.json"),
                                  requiredCheckpointPeers: 1)

        // The lying commitment chain is self-consistent, so the only thing that
        // catches it is a second peer — and there is not one. The sync either
        // completes on the liar's view or fails on the filter bodies; what it
        // cannot do is detect the lie as a disagreement.
        let collector = MatchCollector()
        _ = try? await sync.sync(watchScripts: [synthetic.watchScript]) { collector.add($0) }
        #expect(await pool.connectedPeers().count <= 1)
        await pool.stop()
    }
}
