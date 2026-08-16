import Foundation
import Network
import Testing
@testable import BitcoinP2P

/// PeerPool dial rounds: candidates are raced in parallel with a short
/// per-attempt timeout, the pool fills across mixed accept/reject/timeout
/// candidates, and a round that runs out of candidates reports exhaustion
/// (with `retry()` recovering once a candidate becomes viable). All loopback
/// — no external network.
@Suite("Peer pool dialing")
struct PeerPoolTests {
    /// No DNS seeds, no fallback peers: the pool dials exactly the manual
    /// peers the test gives it.
    private let params = NetworkParams.customSignet(challenge: Data([0x51]))

    @Test("pool fills from mixed accept / reject / silent / refused candidates")
    func mixedCandidates() async throws {
        let goodA = LoopbackNode(params: params)
        let goodB = LoopbackNode(params: params)
        let nonFilter = LoopbackNode(params: params, services: 1) // handshake rejects
        let silent = SilentNode()
        try await goodA.start()
        try await goodB.start()
        try await nonFilter.start()
        try await silent.start()
        defer {
            Task { await goodA.stop() }
            Task { await goodB.stop() }
            Task { await nonFilter.stop() }
            Task { await silent.stop() }
        }
        let refused = PeerEndpoint(host: "127.0.0.1", port: 1) // nothing listens there

        let pool = PeerPool(params: params, peerCount: 2,
                            manualPeers: [refused, await silent.endpoint, await nonFilter.endpoint,
                                          await goodA.endpoint, await goodB.endpoint],
                            dialTimeout: .milliseconds(500))
        await pool.start()
        var endpoints: [PeerEndpoint] = []
        for peer in await pool.connectedPeers() { endpoints.append(await peer.endpoint) }
        #expect(endpoints.count == 2)
        #expect(endpoints.contains(await goodA.endpoint))
        #expect(endpoints.contains(await goodB.endpoint))
        let status = await pool.connectionStatus
        #expect(status.connected == 2)
        #expect(status.target == 2)
        #expect(status.attempts == 5)
        #expect(!status.exhausted)
        await pool.stop()
    }

    @Test("dialing past the target leaves exactly peerCount peers connected")
    func targetIsRespected() async throws {
        var nodes: [LoopbackNode] = []
        for _ in 0 ..< 4 {
            let node = LoopbackNode(params: params)
            try await node.start()
            nodes.append(node)
        }
        defer { for node in nodes { Task { await node.stop() } } }
        var endpoints: [PeerEndpoint] = []
        for node in nodes { endpoints.append(await node.endpoint) }

        let pool = PeerPool(params: params, peerCount: 2, manualPeers: endpoints,
                            dialTimeout: .milliseconds(500))
        await pool.start()
        #expect(await pool.connectedPeers().count == 2)
        await pool.stop()
        #expect(await pool.connectedPeers().isEmpty)
    }

    @Test("a round of silent candidates exhausts in ~one dial timeout, not five")
    func exhaustionIsParallel() async throws {
        var nodes: [SilentNode] = []
        var endpoints: [PeerEndpoint] = []
        for _ in 0 ..< 5 {
            let node = SilentNode()
            try await node.start()
            nodes.append(node)
            endpoints.append(await node.endpoint)
        }
        defer { for node in nodes { Task { await node.stop() } } }

        let pool = PeerPool(params: params, peerCount: 3, manualPeers: endpoints,
                            dialTimeout: .milliseconds(400))
        let start = ContinuousClock.now
        await pool.start()
        let elapsed = ContinuousClock.now - start
        // Serial dialing would take 5 × 400ms of timeouts; racing all five
        // bounds the round at roughly one dial timeout.
        #expect(elapsed < .seconds(2))
        let status = await pool.connectionStatus
        #expect(status.connected == 0)
        #expect(status.exhausted)
        #expect(status.attempts == 5)
        await pool.stop()
    }

    @Test("total dial effort is capped per round")
    func dialAttemptsCapped() async throws {
        var nodes: [SilentNode] = []
        var endpoints: [PeerEndpoint] = []
        for _ in 0 ..< 5 {
            let node = SilentNode()
            try await node.start()
            nodes.append(node)
            endpoints.append(await node.endpoint)
        }
        defer { for node in nodes { Task { await node.stop() } } }

        let pool = PeerPool(params: params, peerCount: 3, manualPeers: endpoints,
                            dialTimeout: .milliseconds(300), maxDialAttempts: 3)
        await pool.start()
        let status = await pool.connectionStatus
        #expect(status.attempts == 3)
        #expect(status.exhausted)
        await pool.stop()
    }

    @Test("exhaustion then retry once a candidate is viable fills the pool")
    func retryAfterExhaustion() async throws {
        // Grab a free port, then close it: the pool's first round is refused.
        let reserved = LoopbackNode(params: params)
        try await reserved.start()
        let port = await reserved.port
        await reserved.stop()

        let endpoint = PeerEndpoint(host: "127.0.0.1", port: port)
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [endpoint],
                            dialTimeout: .milliseconds(400))
        await pool.start()
        var status = await pool.connectionStatus
        #expect(status.connected == 0)
        #expect(status.exhausted)

        // The same endpoint now serves: retry connects without a restart.
        let node = LoopbackNode(params: params, listenPort: port)
        try await node.start()
        defer { Task { await node.stop() } }
        await pool.retry()
        status = await pool.connectionStatus
        #expect(status.connected == 1)
        #expect(!status.exhausted)
        await pool.stop()
    }
}

/// A listener that accepts connections and never speaks — exercises the
/// pool's per-attempt dial timeout.
private actor SilentNode {
    private var listener: NWListener?
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var endpoint: PeerEndpoint { PeerEndpoint(host: "127.0.0.1", port: port) }

    func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "org.btc-swift.tests.silent.conn"))
            Task { await self.hold(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    Task { await self.capturePortAndResume(resumeOnce) }
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    resumeOnce.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "org.btc-swift.tests.silent"))
        }
    }

    func stop() {
        for connection in held { connection.cancel() }
        listener?.cancel()
    }

    private func hold(_ connection: NWConnection) {
        held.append(connection)
    }

    private func capturePortAndResume(_ resumeOnce: ResumeOnce) {
        port = listener?.port?.rawValue ?? 0
        resumeOnce.resume()
    }
}
