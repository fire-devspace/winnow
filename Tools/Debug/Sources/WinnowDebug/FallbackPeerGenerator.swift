import BitcoinP2P
import Foundation

/// Release-path generator for the bundled mainnet fallback peers (#161), run
/// by `scripts/generate-fallback-peers`.
///
/// The verification bar is not re-implemented: `PeerConnection.connect`
/// already refuses any peer whose version does not advertise
/// NODE_COMPACT_FILTERS, so a completed handshake *is* the check the
/// hand-curated list was held to. Spread is enforced with the same
/// `netblock` the pool's diversity policy uses.
///
/// The network part is `run`; everything it decides with is a pure function
/// below, covered offline by `WinnowGenerateTests`.
enum FallbackPeerGenerator {
    /// A peer that completed the handshake, with what its version said.
    struct VerifiedPeer: Equatable, Sendable {
        let endpoint: PeerEndpoint
        let userAgent: String
        let startHeight: Int32
    }

    struct Options {
        static let defaultOutput = "Sources/BitcoinP2P/Protocol/FallbackPeersGenerated.swift"

        /// Past this the returns diminish; Core's contrib/seeds filters to the
        /// same order of magnitude.
        let target: Int
        /// Below this the run fails rather than shipping a thin list: a silent
        /// degradation is exactly what generation exists to prevent.
        let floor: Int
        let out: URL

        init(_ arguments: [String]) throws {
            target = try WinnowGenerate.number("--target", in: arguments) ?? 96
            floor = try WinnowGenerate.number("--floor", in: arguments) ?? 24
            guard floor >= 1, target >= floor else {
                throw GenerateError.usage("--floor must be at least 1 and no more than --target")
            }
            out = WinnowGenerate.option("--out", in: arguments).map { URL(fileURLWithPath: $0) }
                ?? WinnowGenerate.packageRoot.appending(path: Self.defaultOutput)
        }
    }

    static let dialTimeout: Duration = .seconds(5)
    static let parallelDials = 24

    static func run(_ options: Options) async throws {
        let params = NetworkParams.mainnet
        var candidates = await SeedResolver.live().resolveSeeds(params.dnsSeeds, port: params.defaultPort,
                                                                allowPrivate: false)
        candidates.shuffle()
        print("generator: \(candidates.count) candidates from \(params.dnsSeeds.count) seeds")
        guard candidates.count >= options.floor else {
            throw GenerateError.thinList("seed resolution produced only \(candidates.count) candidates")
        }

        var verified: [VerifiedPeer] = []
        var cursor = 0
        while verified.count < options.target, cursor < candidates.count {
            let batch = Array(candidates[cursor ..< min(cursor + parallelDials, candidates.count)])
            cursor += batch.count
            verified = spread(await dial(batch, params: params), keeping: verified)
            print("generator: \(verified.count)/\(options.target) verified after \(cursor) dials")
        }
        guard verified.count >= options.floor else {
            throw GenerateError.thinList("only \(verified.count) filter-serving peers verified")
        }

        let tip = medianTip(verified)
        let (fresh, stale) = partitionByTip(verified, tip: tip)
        for peer in stale {
            print("generator: dropping \(peer.endpoint) at height \(peer.startHeight), "
                  + "\(Int64(tip) - Int64(peer.startHeight)) behind the median \(peer.userAgent)")
        }
        guard fresh.count >= options.floor else {
            throw GenerateError.thinList("only \(fresh.count) peers near the tip")
        }
        let source = render(fresh, tip: tip, date: ISO8601DateFormatter().string(from: Date()))
        try Data(source.utf8).write(to: options.out, options: .atomic)
        print("generator: wrote \(fresh.count) peers, median tip \(tip), to \(options.out.path)")
    }

    /// Dials one batch in parallel. A refused handshake, a timeout and a peer
    /// without NODE_COMPACT_FILTERS are the same answer here: not listed.
    static func dial(_ batch: [PeerEndpoint], params: NetworkParams) async -> [VerifiedPeer] {
        await withTaskGroup(of: VerifiedPeer?.self) { group in
            for endpoint in batch {
                group.addTask { await verify(endpoint, params: params) }
            }
            var collected: [VerifiedPeer] = []
            for await result in group { if let result { collected.append(result) } }
            return collected
        }
    }

    static func verify(_ endpoint: PeerEndpoint, params: NetworkParams) async -> VerifiedPeer? {
        let peer = PeerConnection(endpoint: endpoint, params: params)
        do {
            try await peer.connect(timeout: dialTimeout)
            let verified = VerifiedPeer(endpoint: endpoint, userAgent: await peer.peerUserAgent,
                                        startHeight: await peer.peerStartHeight)
            await peer.disconnect()
            return verified
        } catch {
            return nil
        }
    }

    // MARK: - Pure parts

    /// One peer per netblock, first seen wins, in the order given. A peer whose
    /// block cannot be computed is not a public IP literal and is dropped: the
    /// list is literals only, so no resolver joins the trust story.
    static func spread(_ peers: [VerifiedPeer], keeping existing: [VerifiedPeer] = []) -> [VerifiedPeer] {
        var blocks = Set(existing.compactMap(\.endpoint.netblock))
        var kept = existing
        for peer in peers {
            guard let block = peer.endpoint.netblock, blocks.insert(block).inserted else { continue }
            kept.append(peer)
        }
        return kept
    }

    /// The observed tip: the median of what the verified peers report, which
    /// no single lying peer can move.
    static func medianTip(_ peers: [VerifiedPeer]) -> Int32 {
        precondition(!peers.isEmpty, "no peers to take a median of")
        let heights = peers.map(\.startHeight).sorted()
        return heights[heights.count / 2]
    }

    /// A peer far behind the median tip is in initial download or on a dead
    /// fork, and the pool would only unseat it at first contact
    /// (`PeerPool.staleTipTolerance`). Shipping it wastes the user's first
    /// dials on a peer known to be useless when the list was made.
    static func partitionByTip(_ peers: [VerifiedPeer], tip: Int32) -> (fresh: [VerifiedPeer], stale: [VerifiedPeer]) {
        var fresh: [VerifiedPeer] = []
        var stale: [VerifiedPeer] = []
        for peer in peers {
            if Int64(tip) - Int64(peer.startHeight) > PeerPool.staleTipTolerance {
                stale.append(peer)
            } else {
                fresh.append(peer)
            }
        }
        return (fresh, stale)
    }

    /// The user agent goes into a `//` comment, and a peer chooses its own. A
    /// line break in one would put whatever followed it into the compiled
    /// list, so only printable ASCII — all BIP14 ever needs — survives.
    static func commentSafe(_ userAgent: String) -> String {
        String(userAgent.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F ? Character($0) : "?" })
    }

    /// The generated source, in exactly the shape the rest of the repository
    /// reads: `scripts/check-release-policy` parses the `// Generation:` line
    /// for the date, and `PeerPolicyTests` validates the entries.
    static func render(_ peers: [VerifiedPeer], tip: Int32, date: String) -> String {
        let entries = peers
            .sorted { $0.endpoint.host < $1.endpoint.host }
            .map { peer in
                "        PeerEndpoint(host: \"\(peer.endpoint.host)\", "
                + "port: \(peer.endpoint.port)),  // \(commentSafe(peer.userAgent))"
            }
            .joined(separator: "\n")
        return """
        // GENERATED FILE — edit by regenerating, not by hand.
        //
        // scripts/generate-fallback-peers rewrites this file on the release path
        // (#161) with `winnow-debug generate fallback-peers` (Tools/Debug): it resolves
        // the mainnet DNS seeds, dials candidates with the same PeerConnection the
        // app uses — whose handshake already refuses any peer not advertising
        // NODE_COMPACT_FILTERS — and keeps a /16-spread selection, checked by the
        // same `PeerEndpoint.netblock` the pool's diversity policy uses.
        //
        // The committed copy is the last verified generation and the build's fallback;
        // a release regenerates so freshness tracks releases rather than memory.
        // `PeerPolicyTests` validates this file on every CI run.
        //
        // What this is not, recorded so it is not over-claimed: the list inherits
        // whatever the generating host could see, and generation is not reproducible —
        // two runs give different lists. The generation log is kept as a release
        // artifact so the list is auditable even though it is not reproducible.
        //
        // Generation: \(date), \(peers.count) peers verified, median reported
        // tip \(tip).
        extension NetworkParams {
            static let generatedMainnetFallbackPeers: [PeerEndpoint] = [
        \(entries)
            ]
        }

        """
    }
}
