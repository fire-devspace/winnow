import Foundation
import Testing
@testable import BitcoinP2P

/// DoH dns-json parse, RFC1918/loopback filter, getaddrinfo fallback, and
/// PeerPool wiring. All loopback / fixtures — no live resolver.
@Suite("DNS seed resolver (DoH)")
struct SeedResolverTests {
    @Test("dns-json A/AAAA parse keeps public IPs and drops RFC1918 on mainnet")
    func parseAndFilterPublic() throws {
        let hosts = try DNSJSON.hosts(from: vectorData("doh-a-and-aaaa.json"))
        #expect(hosts == ["1.2.3.4", "5.6.7.8", "10.0.0.1", "192.168.1.9", "2001:db8::1"])

        let publicNets = SeedResolver.endpoints(hosts: hosts, port: 8333, allowPrivate: false)
        #expect(Set(publicNets.map(\.host)) == ["1.2.3.4", "5.6.7.8", "2001:db8::1"])
        #expect(publicNets.allSatisfy { $0.port == 8333 })

        let custom = SeedResolver.endpoints(hosts: hosts, port: 38_333, allowPrivate: true)
        #expect(Set(custom.map(\.host)) == Set(hosts))
    }

    @Test("CNAME rows are ignored; the following A is kept")
    func cnameThenA() throws {
        let hosts = try DNSJSON.hosts(from: vectorData("doh-cname-then-a.json"))
        #expect(hosts == ["9.9.9.9"])
    }

    @Test("non-zero dns-json Status yields no hosts")
    func servfail() throws {
        #expect(try DNSJSON.hosts(from: vectorData("doh-servfail.json")).isEmpty)
    }

    @Test("RFC1918-only DoH answers fall back to getaddrinfo on public nets")
    func poisonedDoHFallsBack() async {
        let fixture = try! vectorData("doh-rfc1918-only.json")
        let fallback = PeerEndpoint(host: "8.8.8.8", port: 8333)
        let resolver = SeedResolver.live(
            fetchJSON: { _, _ in fixture },
            systemResolve: { _, port in [PeerEndpoint(host: "8.8.8.8", port: port)] }
        )
        let got = await resolver.resolve(host: "poison.example.test", port: 8333, allowPrivate: false)
        #expect(got == [fallback])
    }

    @Test("RFC1918-only DoH answers are kept on a custom signet")
    func customSignetKeepsPrivate() async {
        let fixture = try! vectorData("doh-rfc1918-only.json")
        let resolver = SeedResolver.live(
            fetchJSON: { _, _ in fixture },
            systemResolve: { _, _ in [] }
        )
        let got = await resolver.resolve(host: "poison.example.test", port: 38_401, allowPrivate: true)
        #expect(Set(got.map(\.host)) == ["10.1.2.3", "172.16.0.4", "192.168.0.5", "127.0.0.1"])
        #expect(got.allSatisfy { $0.port == 38_401 })
    }

    @Test("DoH transport failure falls back to getaddrinfo")
    func dohFailureFallsBack() async {
        let resolver = SeedResolver.live(
            fetchJSON: { _, _ in throw URLError(.notConnectedToInternet) },
            systemResolve: { host, port in
                #expect(host == "seed.example.test")
                return [PeerEndpoint(host: "1.1.1.1", port: port)]
            }
        )
        let got = await resolver.resolve(host: "seed.example.test", port: 8333, allowPrivate: false)
        #expect(got == [PeerEndpoint(host: "1.1.1.1", port: 8333)])
    }

    @Test("filter rejects hostnames, loopback, link-local, and mapped RFC1918")
    func filterEdges() {
        #expect(!SeedAddressFilter.accepts("seed.example.test", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("seed.example.test", allowPrivate: true))
        #expect(!SeedAddressFilter.accepts("127.0.0.1", allowPrivate: false))
        #expect(SeedAddressFilter.accepts("127.0.0.1", allowPrivate: true))
        #expect(!SeedAddressFilter.accepts("169.254.1.1", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("0.0.0.0", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("::1", allowPrivate: false))
        #expect(SeedAddressFilter.accepts("::1", allowPrivate: true))
        #expect(!SeedAddressFilter.accepts("fe80::1", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("fc00::1", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("::ffff:10.0.0.1", allowPrivate: false))
        #expect(SeedAddressFilter.accepts("::ffff:1.2.3.4", allowPrivate: false))
        #expect(SeedAddressFilter.accepts("8.8.8.8", allowPrivate: false))
        #expect(!SeedAddressFilter.accepts("224.0.0.1", allowPrivate: false))
    }

    @Test("public signet/mainnet refuse private seed answers; custom signet allows them")
    func networkPolicy() {
        #expect(!NetworkParams.mainnet.allowsPrivateSeedAddresses)
        #expect(!NetworkParams.signet.allowsPrivateSeedAddresses)
        #expect(!NetworkParams.mainnet.isCustomSignet)
        #expect(!NetworkParams.signet.isCustomSignet)
        let custom = NetworkParams.customSignet(challenge: Data([0x51]))
        #expect(custom.isCustomSignet)
        #expect(custom.allowsPrivateSeedAddresses)
    }

    @Test("PeerPool skips seed resolution when a manual peer fills the slot")
    func poolSkipsSeedsWhenLocalFills() async throws {
        let params = seededCustomParams(dnsSeeds: ["seed.example.test"])
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let flag = Flag()
        let resolver = SeedResolver { _, _, _ in
            flag.value = true
            return []
        }
        let pool = PeerPool(params: params, peerCount: 1,
                            manualPeers: [await node.endpoint],
                            dialTimeout: .milliseconds(500), seedResolver: resolver)
        await pool.start()
        #expect(await pool.connectionStatus.connected == 1)
        #expect(!flag.value)
        await pool.stop()
    }

    @Test("PeerPool dials DoH-resolved seed endpoints")
    func poolUsesResolver() async throws {
        let params = seededCustomParams(dnsSeeds: ["seed.example.test"])
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let endpoint = await node.endpoint
        let resolver = SeedResolver { _, _, _ in [endpoint] }
        let pool = PeerPool(params: params, peerCount: 1,
                            dialTimeout: .milliseconds(500), seedResolver: resolver)
        await pool.start()
        let status = await pool.connectionStatus
        #expect(status.connected == 1)
        #expect(!status.exhausted)
        await pool.stop()
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}

private func seededCustomParams(dnsSeeds: [String]) -> NetworkParams {
    let base = NetworkParams.customSignet(challenge: Data([0x51]))
    return NetworkParams(
        network: base.network,
        magic: base.magic,
        defaultPort: base.defaultPort,
        genesisTime: base.genesisTime,
        genesisBits: base.genesisBits,
        genesisNonce: base.genesisNonce,
        genesisMerkleRoot: base.genesisMerkleRoot,
        genesisHash: base.genesisHash,
        powLimit: base.powLimit,
        dnsSeeds: dnsSeeds
    )
}
