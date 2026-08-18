import Foundation

public enum PeerPoolHeaderSyncError: LocalizedError, Equatable {
    case noPeers
    case exhausted(attempts: Int, lastError: String)

    public var errorDescription: String? {
        switch self {
        case .noPeers:
            "No Bitcoin peers are available for block-header sync."
        case let .exhausted(attempts, lastError):
            "Winnow tried \(attempts) Bitcoin peer\(attempts == 1 ? "" : "s"), but none supplied a usable block-header chain. Last error: \(lastError)"
        }
    }
}

/// A small pool of outbound peers (default 3). Candidates come from manually
/// supplied endpoints, a persisted good-peers JSON file, the network's
/// hardcoded fallback peers, and DNS seeds resolved over DoH (dns-json)
/// with getaddrinfo as fallback. Dials race a batch of candidates at once
/// (short per-attempt timeout) so a fresh launch fills the pool in seconds;
/// a round that runs out of candidates below target is reported as
/// `exhausted` in `connectionStatus`. A monitor task prunes dead connections
/// and connects replacements. Deliberately simple: no scoring buckets, no
/// addr gossip — misbehaving peers are dropped and replaced.
public actor PeerPool {
    public let params: NetworkParams
    public let peerCount: Int
    public let manualPeers: [PeerEndpoint]
    /// BIP37 relay flag for connections this pool creates: true asks peers to
    /// inv every relayed transaction (bounded mempool windows, §2.8, fetch
    /// them with getdata; without a window open the invs are simply dropped).
    public let relayPreference: Bool
    /// Per-attempt TCP+handshake timeout for pool-created connections.
    public let dialTimeout: Duration
    /// How many candidates are dialed concurrently per round.
    public let maxParallelDials: Int
    /// Total dial attempts per round — bounds the effort before the round
    /// gives up and reports exhaustion.
    public let maxDialAttempts: Int
    /// JSON file where known-good peers are persisted.
    private let peersFileURL: URL?
    /// DNS-seed resolver (DoH, then getaddrinfo). Injectable for tests.
    private let seedResolver: SeedResolver

    private var peers: [PeerConnection] = []
    private var knownGood: Set<PeerEndpoint> = []
    private var monitorTask: Task<Void, Never>?
    private var started = false
    private var replenishing = false
    private var attemptsThisRound = 0
    private var exhausted = false
    /// Endpoints rejected for a protocol/chain failure during this pool run.
    /// Without this set a manual or persisted bad peer is immediately dialed
    /// again after `misbehaving`, starving healthy fallback candidates.
    private var rejectedForSession: Set<PeerEndpoint> = []

    /// UI-facing snapshot of the pool's connection progress.
    public struct ConnectionStatus: Sendable, Equatable {
        /// Currently connected peers.
        public var connected: Int
        /// The pool's target size.
        public var target: Int
        /// A dial round is in flight.
        public var dialing: Bool
        /// Dials launched in the current/last round.
        public var attempts: Int
        /// The last round ran out of candidates below target — no peers at
        /// all when `connected == 0` (the UI's error + retry state).
        public var exhausted: Bool
    }

    public var connectionStatus: ConnectionStatus {
        ConnectionStatus(connected: peers.count, target: peerCount,
                         dialing: replenishing, attempts: attemptsThisRound,
                         exhausted: exhausted)
    }

    public init(params: NetworkParams, peerCount: Int = 3,
                manualPeers: [PeerEndpoint] = [], peersFileURL: URL? = nil,
                relayPreference: Bool = false,
                dialTimeout: Duration = .seconds(5),
                maxParallelDials: Int = 5, maxDialAttempts: Int = 50,
                seedResolver: SeedResolver = .live()) {
        self.params = params
        self.peerCount = peerCount
        self.manualPeers = manualPeers
        self.peersFileURL = peersFileURL
        self.relayPreference = relayPreference
        self.dialTimeout = dialTimeout
        self.maxParallelDials = maxParallelDials
        self.maxDialAttempts = maxDialAttempts
        self.seedResolver = seedResolver
        if let peersFileURL,
           let data = try? Data(contentsOf: peersFileURL),
           let stored = try? JSONDecoder().decode([PeerEndpoint].self, from: data) {
            knownGood = Set(stored)
        }
    }

    /// Connects to `peerCount` peers and starts the replacement monitor.
    public func start() async {
        guard !started else { return }
        started = true
        await replenish()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.pruneAndReplenish()
            }
        }
    }

    /// Disconnects everything and persists the good-peers list.
    public func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        started = false
        for peer in peers { await peer.disconnect() }
        peers = []
        rejectedForSession = []
        persistKnownGood()
    }

    /// Currently connected peers (snapshot).
    public func connectedPeers() -> [PeerConnection] { peers }

    public func randomPeer() -> PeerConnection? { peers.randomElement() }

    /// Disconnects a misbehaving/broken peer and connects a replacement.
    public func misbehaving(_ peer: PeerConnection, reason: String) async {
        await peer.disconnect()
        peers.removeAll { $0.endpoint == peer.endpoint }
        knownGood.remove(peer.endpoint)
        rejectedForSession.insert(peer.endpoint)
        await replenish()
    }

    /// Syncs headers against connected peers with bounded failover. Header
    /// batches already accepted by `HeaderChain` remain persisted, so the next
    /// peer resumes from that progress rather than restarting at genesis.
    /// Local storage failures are never blamed on (or retried against) peers.
    public func syncHeaders(_ chain: HeaderChain, timeoutPerPeer: Duration = .seconds(30),
                            maxAttempts: Int = 6) async throws {
        precondition(maxAttempts > 0)
        var attempts = 0
        var lastError: (any Error)?

        while attempts < maxAttempts {
            guard let peer = peers.first else {
                if attempts == 0 { throw PeerPoolHeaderSyncError.noPeers }
                break
            }
            attempts += 1
            do {
                try await chain.sync(using: peer, timeout: timeoutPerPeer)
                return
            } catch let error as HeaderChainError {
                switch error {
                case .storageCorrupt, .storageUnavailable:
                    throw error
                default:
                    break
                }
                lastError = error
                await misbehaving(peer, reason: error.localizedDescription)
            } catch is CancellationError {
                // App lifecycle cancellation is local control flow, not peer
                // misconduct. Keep the connection eligible for the next
                // foreground sync instead of poisoning the session pool.
                throw CancellationError()
            } catch {
                lastError = error
                // A peer that disconnects, times out, or violates framing in
                // the middle of header sync is unsuitable for this run too.
                await misbehaving(peer, reason: error.localizedDescription)
            }
        }

        throw PeerPoolHeaderSyncError.exhausted(
            attempts: attempts,
            lastError: lastError?.localizedDescription ?? "no additional peers were available")
    }

    // MARK: - Internals

    private func pruneAndReplenish() async {
        var alive: [PeerConnection] = []
        for peer in peers where await peer.isConnected {
            alive.append(peer)
        }
        peers = alive
        await replenish()
    }

    /// Dials again immediately (UI retry after exhaustion). No-op while a
    /// round is in flight, the pool is full, or the pool is stopped.
    public func retry() async {
        await replenish()
    }

    /// Races up to `maxParallelDials` candidates at a time (each with the
    /// short `dialTimeout`) until the pool is full or the round's candidates
    /// — capped at `maxDialAttempts` — are used up. In-flight stragglers are
    /// never cancelled (PeerConnection's checked continuations do not respond
    /// to cancellation); they resolve on their own timeout and a late success
    /// with no slot left is disconnected again.
    private func replenish() async {
        guard started, !replenishing, peers.count < peerCount else { return }
        replenishing = true
        attemptsThisRound = 0
        exhausted = false
        defer { replenishing = false }

        // Dial manual / persisted / fallback first. Resolve DNS seeds only
        // if those sources cannot fill the pool — a working manual peer
        // must not wait on DoH.
        var queue = localCandidates(excluding: Set(peers.map(\.endpoint)).union(rejectedForSession))
        var resolvedSeeds = false
        var needed = peerCount - peers.count
        var next = 0
        await withTaskGroup(of: (PeerEndpoint, PeerConnection?).self) { group in
            var running = 0
            while needed > 0, started {
                if next >= queue.count && !resolvedSeeds {
                    resolvedSeeds = true
                    var seen = Set(peers.map(\.endpoint)).union(rejectedForSession)
                    seen.formUnion(queue)
                    queue.append(contentsOf: await seedCandidates(excluding: seen))
                }
                while next < queue.count, running < maxParallelDials,
                      attemptsThisRound < maxDialAttempts {
                    let endpoint = queue[next]
                    next += 1
                    running += 1
                    attemptsThisRound += 1
                    group.addTask { [params, relayPreference, dialTimeout] in
                        let peer = PeerConnection(endpoint: endpoint, params: params,
                                                  relayPreference: relayPreference)
                        do {
                            try await peer.connect(timeout: dialTimeout)
                            return (endpoint, peer)
                        } catch {
                            return (endpoint, nil) // unreachable or bad handshake
                        }
                    }
                }
                guard running > 0, let (endpoint, dialed) = await group.next() else { break }
                running -= 1
                guard let peer = dialed else { continue }
                if started, needed > 0, !peers.contains(where: { $0.endpoint == endpoint }) {
                    peers.append(peer)
                    needed -= 1
                    if knownGood.insert(endpoint).inserted { persistKnownGood() }
                } else {
                    await peer.disconnect() // slot filled while this dial was in flight
                }
            }
        }
        exhausted = peers.count < peerCount
    }

    /// Manual peers, then persisted good peers, then hardcoded fallbacks.
    private func localCandidates(excluding connected: Set<PeerEndpoint>) -> [PeerEndpoint] {
        let ordered = manualPeers + Array(knownGood.subtracting(manualPeers)) + params.fallbackPeers
        var seen = connected
        return ordered.filter { seen.insert($0).inserted }
    }

    /// DNS-seed results (DoH, then getaddrinfo). Called only when local
    /// candidates did not fill the pool.
    private func seedCandidates(excluding connected: Set<PeerEndpoint>) async -> [PeerEndpoint] {
        let seeds = await seedResolver.resolveSeeds(
            params.dnsSeeds, port: params.defaultPort,
            allowPrivate: params.allowsPrivateSeedAddresses
        )
        var seen = connected
        return seeds.filter { seen.insert($0).inserted }
    }

    private func persistKnownGood() {
        guard let peersFileURL else { return }
        let endpoints = Array(knownGood.prefix(100))
        if let data = try? JSONEncoder().encode(endpoints) {
            try? data.write(to: peersFileURL, options: .atomic)
        }
    }
}
