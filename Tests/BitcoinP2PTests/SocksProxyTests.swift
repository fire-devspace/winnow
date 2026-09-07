import BitcoinCore
import Foundation
import Network
import Testing
import TestSupport
@testable import BitcoinP2P

@Suite("SOCKS5 proxying", .timeLimit(.minutes(1)))
struct SocksProxyTests {
    @Test("a peer is dialled by name through the proxy and the handshake runs over the circuit")
    func connectsByName() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let proxy = FakeSocksProxy(upstreamPort: await node.endpoint.port)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        // A name no resolver could answer: only the proxy can take it.
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "winnowtestpeer.onion", port: 8333),
                                  params: params, socksProxy: await proxy.endpoint)
        try await peer.connect(timeout: .seconds(10))
        #expect(await peer.isConnected)
        #expect(await peer.peerUserAgent.isEmpty == false, "the version exchange ran over the circuit")
        #expect(await proxy.requestedHost == "winnowtestpeer.onion", "the name went to the proxy unresolved")
        #expect(await proxy.requestedPort == 8333)
        #expect(await node.nextMessage(command: "verack", timeout: .seconds(5)) != nil)
        await peer.disconnect()
    }

    @Test("a proxy that cannot reach the peer reports a transport failure, not a protocol fault")
    func proxyRefusal() async throws {
        let params = NetworkParams.signet
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 0x04) // host unreachable
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "nowhere.onion", port: 8333),
                                  params: params, socksProxy: await proxy.endpoint)
        do {
            try await peer.connect(timeout: .seconds(10))
            Issue.record("the connection should have failed")
        } catch let error as PeerError {
            #expect(error.isTransport, "\(error)")
            #expect(error.localizedDescription.contains("host unreachable"))
        }
        #expect(await peer.isConnected == false)
    }

    @Test("without a proxy the dial is direct and unchanged")
    func directDialUnchanged() async throws {
        let params = NetworkParams.signet
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = PeerConnection(endpoint: await node.endpoint, params: params)
        try await peer.connect(timeout: .seconds(10))
        #expect(await peer.socksProxy == nil)
        #expect(await peer.isConnected)
        await peer.disconnect()
    }
}
