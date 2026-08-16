import Foundation

/// A small pool of outbound peers (default 3). Candidates come from manually
/// supplied endpoints, a persisted good-peers JSON file, the network's
/// hardcoded fallback peers, and DNS seeds resolved with getaddrinfo. Dials
/// race a batch of candidates at once (short per-attempt timeout) so a fresh
/// launch fills the pool in seconds; a round that runs out of candidates
/// below target is reported as `exhausted` in `connectionStatus`. A monitor
/// task prunes dead connections and connects replacements. Deliberately
/// simple: no scoring buckets, no addr gossip — misbehaving peers are dropped
/// and replaced.
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

    private var peers: [PeerConnection] = []
    private var knownGood: Set<PeerEndpoint> = []
    private var monitorTask: Task<Void, Never>?
    private var started = false
    private var replenishing = false
    private var attemptsThisRound = 0
    private var exhausted = false

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
                maxParallelDials: Int = 5, maxDialAttempts: Int = 50) {
        self.params = params
        self.peerCount = peerCount
        self.manualPeers = manualPeers
        self.peersFileURL = peersFileURL
        self.relayPreference = relayPreference
        self.dialTimeout = dialTimeout
        self.maxParallelDials = maxParallelDials
        self.maxDialAttempts = maxDialAttempts
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
        await replenish()
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

        let queue = Array(candidates(excluding: Set(peers.map(\.endpoint))).prefix(maxDialAttempts))
        var needed = peerCount - peers.count
        var next = 0
        await withTaskGroup(of: (PeerEndpoint, PeerConnection?).self) { group in
            var running = 0
            while needed > 0, started {
                while next < queue.count, running < maxParallelDials {
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

    /// Manual peers first, then persisted good peers, then the hardcoded
    /// fallback peers racing the DNS-seed results.
    private func candidates(excluding connected: Set<PeerEndpoint>) -> [PeerEndpoint] {
        var ordered = manualPeers + knownGood.subtracting(manualPeers) + params.fallbackPeers
        for seed in params.dnsSeeds.shuffled() {
            ordered.append(contentsOf: Self.resolve(host: seed, port: params.defaultPort))
        }
        var seen = connected
        return ordered.filter { seen.insert($0).inserted }
    }

    private func persistKnownGood() {
        guard let peersFileURL else { return }
        let endpoints = Array(knownGood.prefix(100))
        if let data = try? JSONEncoder().encode(endpoints) {
            try? data.write(to: peersFileURL, options: .atomic)
        }
    }

    /// Resolves a DNS seed to concrete endpoints via getaddrinfo.
    static func resolve(host: String, port: UInt16) -> [PeerEndpoint] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var endpoints: [PeerEndpoint] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            defer { current = info.pointee.ai_next }
            guard info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6 else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                     &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let bytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            endpoints.append(PeerEndpoint(host: String(decoding: bytes, as: UTF8.self), port: port))
        }
        return endpoints
    }
}
