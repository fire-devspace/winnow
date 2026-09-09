import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The transport's buffer for messages nobody asked for: what a peer can
/// leave behind by talking, over the real loopback transport rather than a
/// stub, because the retention being measured is what the framer and the
/// receive loop actually hand over.
///
/// The sibling of the burst bound in `FilterSyncTests`: that one bounds what
/// a peer sends in answer to a request, this one bounds what it sends unbidden.
@Suite("PeerConnection gossip buffer")
struct PeerConnectionTests {

    /// A ping from the node, answered by the client's pong. TCP delivers in
    /// order and the receive loop reads in order, so the pong is the client
    /// saying it has finished with everything sent before the ping — which is
    /// how a test waits out gossip that produces no reply of its own.
    private func drain(_ node: LoopbackNode) async -> Bool {
        try? await node.send(.ping(0x5EED))
        return await node.nextMessage(command: "pong", timeout: .seconds(120)) != nil
    }

    /// The message cap bounds messages, not memory. Under a command nobody
    /// collects every message goes to the buffer, and 256 of them at the
    /// framer's maximum is a gigabyte on one connection that is still up,
    /// times the pool's seats. Measured here at a mild 1 MB apiece: without
    /// the byte ceiling this leaves 256,000,000 bytes behind.
    ///
    /// A flood is not misconduct, so the connection stays: old gossip goes
    /// and the peer keeps talking.
    @Test("a flood of unsolicited messages is bounded in bytes, not only in count")
    func unsolicitedFloodIsBoundedInBytes() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet)
        try await peer.connect()
        let empty = await peer.backlogSize
        #expect(empty.messages == 0)
        #expect(empty.bytes == 0)

        let gossip = PeerMessage.unknown(command: "gossip",
                                         payload: Data(repeating: 0xAB, count: 1_000_000))
        for _ in 0 ..< 300 { try await node.send(gossip) }
        #expect(await drain(node))

        let size = await peer.backlogSize
        #expect(size.bytes <= PeerConnection.defaultBacklogByteLimit)
        #expect(size.messages <= PeerConnection.backlogLimit)
        // Both bounds hold together: eight of the three hundred, the newest,
        // for exactly the ceiling.
        #expect(size.messages == 8)
        #expect(size.bytes == 8_000_000)
        #expect(await peer.isConnected)
        await peer.disconnect()
    }

    /// The ceiling is derived from honest traffic, so honest traffic must fit
    /// with room to spare. Four maximal invs — 50,000 vectors each, the most
    /// `InventoryPayload` will decode — is more than a real peer announces
    /// before a subscriber drains, and none of it is evicted.
    @Test("an honest inv burst inside the ceiling is kept whole")
    func honestInvBurstIsKeptWhole() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet)
        try await peer.connect()

        let vectors = (0 ..< 50_000).map { index in
            InventoryVector(type: .tx, hash: Data(repeating: UInt8(index % 251), count: 32))
        }
        let inv = PeerMessage.inv(InventoryPayload(vectors))
        let invBytes = inv.payload.count
        #expect(invBytes == 1_800_003) // 50,000 x 36, plus the three-byte count
        for _ in 0 ..< 4 { try await node.send(inv) }
        #expect(await drain(node))

        let size = await peer.backlogSize
        #expect(size.messages == 4)
        #expect(size.bytes == 4 * invBytes)
        #expect(size.bytes <= PeerConnection.defaultBacklogByteLimit)
        #expect(await peer.isConnected)
        await peer.disconnect()
    }

    /// One message larger than the whole buffer is the exception to dropping
    /// old gossip: keeping it would evict every other entry to make room for
    /// something nobody asked for, so the peer could empty the buffer at will.
    ///
    /// Not five megabytes against the default ceiling, which is the shape
    /// this reads like: `MessageFramer.maxPayloadSize` refuses any payload
    /// over 4,000,000 with its own error first, so at a ceiling of eight
    /// megabytes no single message can reach this branch at all. A connection
    /// given a smaller buffer can, and that is the connection the branch is
    /// there for.
    @Test("an unsolicited message larger than the whole buffer drops the peer")
    func oversizedUnsolicitedMessageDropsThePeer() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }

        let peer = PeerConnection(endpoint: await node.endpoint, params: .signet,
                                  backlogByteLimit: 1_000_000)
        try await peer.connect()
        let failures = EventCollector<PeerError>()
        let events = await peer.events()
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch let error as PeerError {
                failures.add(error)
            } catch {}
        }
        defer { consumer.cancel() }

        try await node.send(.unknown(command: "gossip",
                                     payload: Data(repeating: 0xAB, count: 2_000_000)))
        #expect(await pollUntil { await !peer.isConnected })
        #expect(await pollUntil { failures.events.count == 1 })
        guard case let .protocolViolation(reason)? = failures.events.first else {
            Issue.record("expected a protocol violation, got \(String(describing: failures.events.first))")
            return
        }
        #expect(reason.contains("unsolicited gossip of 2000000 bytes"))
        let size = await peer.backlogSize
        #expect(size.bytes == 0)
    }
}
