import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// How the pool decides *which* peers to reach for, before any of them are
/// dialled: the diversity ceilings, where seed addresses come from and which
/// of them are usable, and the committed fallback list of last resort.
///
/// Merged from `PeerDiversityTests`, `SeedResolverTests` and
/// `FallbackPeerListTests`; each `// MARK:` below is one of those suites, in
/// that order. None of the three carried a trait, so this one carries none.
///
/// Almost all of it is pure policy against fixtures. The two exceptions are
/// the last cases in the seed-resolver section, which prove the pool actually
/// consults (or skips) a resolver and so dial a loopback node — as they did
/// before the merge.
@Suite("Peer policy")
struct PeerPolicyTests {

    // MARK: - Peer diversity

    // The pool must not end up behind one operator (#3, #4).
    //
    // `replenish` races every candidate and keeps whichever connects first. On a
    // hostile network that is exactly the wrong rule: an attacker running nodes
    // near the device wins every latency race, and can take every slot without
    // doing anything a peer is not allowed to do. Nothing about the wire protocol
    // detects this — every one of those peers behaves correctly and agrees with
    // itself.
    //
    // The two rules here are ceilings, not quotas: they say what a pool may not
    // become, never what it must contain. A quota would refuse to connect at all
    // when a class is unreachable, trading a certain outage for a possible
    // attacker.
    //
    // The owner decision this backs (2026-08-23) was to accept single-peer
    // operation rather than fail closed, with peer diversity as the mitigation.

    private func policy(_ peerCount: Int = 3) -> DiversityPolicy {
        DiversityPolicy(peerCount: peerCount)
    }

    private func candidate(_ host: String, _ source: PeerSource) -> PeerCandidate {
        PeerCandidate(endpoint: PeerEndpoint(host: host, port: 8333), source: source)
    }

    // MARK: Netblock

    @Test("IPv4 groups by /16 and IPv6 by /32")
    func netblockGrouping() {
        #expect(PeerEndpoint.netblock(forHost: "47.206.253.100") == "v4:47.206")
        #expect(PeerEndpoint.netblock(forHost: "47.206.1.1") == "v4:47.206")
        #expect(PeerEndpoint.netblock(forHost: "47.207.253.100") != "v4:47.206")
        #expect(PeerEndpoint.netblock(forHost: "2a01:4f8:1:2::1") == "v6:2a01:04f8")
        #expect(PeerEndpoint.netblock(forHost: "2a01:4f8:9:9::9") == "v6:2a01:04f8")
        #expect(PeerEndpoint.netblock(forHost: "2a02:4f8:1:2::1") != "v6:2a01:04f8")
    }

    /// Unrestricted, and for two different reasons — see `netblock`.
    @Test("hostnames and non-public addresses are not restricted")
    func unrestrictedHosts() {
        #expect(PeerEndpoint.netblock(forHost: "node.example.com") == nil)
        #expect(PeerEndpoint.netblock(forHost: "127.0.0.1") == nil, "a loopback test pool")
        #expect(PeerEndpoint.netblock(forHost: "192.168.1.10") == nil, "a home network")
        #expect(PeerEndpoint.netblock(forHost: "10.0.0.5") == nil)
        #expect(PeerEndpoint.netblock(forHost: "::1") == nil)
        #expect(PeerEndpoint.netblock(forHost: "fe80::1") == nil)
        #expect(PeerEndpoint.netblock(forHost: "not an address") == nil)
    }

    @Test("a second peer from the same block is refused")
    func sameBlockRefused() {
        let seated = [candidate("47.206.253.100", .fallback)]
        #expect(policy().admits(candidate("47.206.1.1", .dnsSeed), given: seated) == false,
                "one operator's neighbouring addresses are close to one peer")
        #expect(policy().admits(candidate("74.209.75.75", .dnsSeed), given: seated))
    }

    /// The rule must not stop a loopback or home-network pool from filling, or
    /// it breaks a working setup to defend against nothing.
    @Test("several peers on one private network all connect")
    func privateNetworkUnaffected() {
        var seated: [PeerCandidate] = []
        for port in 0 ..< 3 {
            let next = PeerCandidate(endpoint: PeerEndpoint(host: "127.0.0.1",
                                                            port: UInt16(18_333 + port)),
                                     source: .manual)
            #expect(policy().admits(next, given: seated))
            seated.append(next)
        }
    }

    // MARK: Source class

    @Test("no source class may hold every slot")
    func noClassOwnsThePool() {
        let seated = [candidate("1.1.1.1", .persisted), candidate("2.2.2.2", .persisted)]
        #expect(policy().admits(candidate("3.3.3.3", .persisted), given: seated) == false,
                "the third slot must come from somewhere else")
        #expect(policy().admits(candidate("3.3.3.3", .fallback), given: seated))
        #expect(policy().admits(candidate("3.3.3.3", .dnsSeed), given: seated))
    }

    /// Two of one class is fine — the rule is a ceiling on total capture, not a
    /// requirement that every class be represented.
    @Test("two of one class is allowed")
    func twoOfOneClassAllowed() {
        let seated = [candidate("1.1.1.1", .persisted)]
        #expect(policy().admits(candidate("2.2.2.2", .persisted), given: seated))
    }

    /// A peer the user typed in is instruction, not selection. Someone who
    /// configures three of their own nodes must get three.
    @Test("manual peers are exempt from the source ceiling")
    func manualPeersExempt() {
        let seated = [candidate("1.1.1.1", .manual), candidate("2.2.2.2", .manual)]
        #expect(policy().admits(candidate("3.3.3.3", .manual), given: seated))
    }

    /// …but not from the netblock rule: choosing two neighbouring addresses by
    /// hand does not make them independent.
    @Test("manual peers are still subject to the netblock rule")
    func manualPeersStillBlocked() {
        let seated = [candidate("47.206.253.100", .manual)]
        #expect(policy().admits(candidate("47.206.9.9", .manual), given: seated) == false)
    }

    /// A single-slot pool has nothing to diversify.
    @Test("a one-peer pool admits anything")
    func singleSlotPool() {
        #expect(policy(1).admits(candidate("1.1.1.1", .persisted),
                                 given: [candidate("2.2.2.2", .persisted)]))
    }

    // MARK: The comparison that consumes the diversity

    /// The pool's ceilings only buy anything if the check that compares peers
    /// actually looks at more than one source.
    ///
    /// The cfcheckpt comparison takes the first `requiredCheckpointPeers`
    /// connected peers. At two, and with a ceiling that permits two peers to
    /// share a class, the comparison could run entirely inside one source —
    /// the exact situation #3 exists to prevent, in the exact place the
    /// evidence is supposed to be cross-checked.
    ///
    /// Consulting the whole pool removes it: no class may hold every slot, so
    /// a full-pool comparison spans more than one source by construction. This
    /// pins the coupling, because the guarantee lives in the two numbers
    /// agreeing and nothing else would notice if one moved.
    @Test("the checkpoint comparison covers the whole pool")
    func checkpointComparisonSpansThePool() async throws {
        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: 0)

        let seats = await PeerPool(params: .signet, manualPeers: []).peerCount
        let consulted = await filters.requiredCheckpointPeers
        #expect(consulted >= seats,
                "a comparison narrower than the pool can sit inside one source class")

        // …and the ceiling is what makes that span classes.
        let seated = [candidate("1.1.1.1", .persisted), candidate("2.2.2.2", .persisted)]
        #expect(policy(seats).admits(candidate("3.3.3.3", .persisted), given: seated) == false)
    }

    /// A peer that was manual once and has since been removed from settings
    /// must lose the ceiling exemption with it.
    ///
    /// The exemption exists because a configured peer is an instruction, and an
    /// instruction that has been withdrawn is not one any more. Keeping it
    /// would mean a transient settings entry buys standing that outlives it —
    /// so a peer briefly typed in, or briefly injected, would stay
    /// ceiling-exempt for the life of the peers file.
    @Test("a manual peer removed from settings loses its exemption")
    func withdrawnManualPeerDecays() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("winnow-decay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // A peers file remembering it as manual, and settings that no longer
        // list it.
        let endpoint = PeerEndpoint(host: "47.206.253.100", port: 8333)
        let stored = PersistedPeers([PeerCandidate(endpoint: endpoint, source: .manual)])
        try JSONEncoder().encode(stored).write(to: file)

        let pool = PeerPool(params: .signet, peerCount: 3, manualPeers: [],
                            peersFileURL: file)
        let classes = await pool.candidateSourcesForTest()
        #expect(classes[endpoint] == .persisted,
                "an instruction that has been withdrawn is not an instruction")
    }

    // MARK: The peers file

    /// A file written before this change is a bare array with no class. It must
    /// still load, and its entries are `persisted` because that is what they
    /// are: peers this device connected to on an earlier run.
    @Test("a pre-existing peers file still loads")
    func legacyPeersFileLoads() throws {
        let endpoints = [PeerEndpoint(host: "47.206.253.100", port: 8333),
                         PeerEndpoint(host: "74.209.75.75", port: 8333)]
        let data = try JSONEncoder().encode(endpoints)
        let decoded = try #require(PersistedPeers.decode(data))
        #expect(decoded.map(\.endpoint) == endpoints)
        #expect(decoded.allSatisfy { $0.source == .persisted })
    }

    /// The class has to survive a restart, because a successful dial promotes
    /// an endpoint into the known-good set whatever its origin. Without this,
    /// every peer collapses to `persisted` after its first connection and the
    /// pool forgets it ever had a diverse set of sources.
    @Test("the source class round-trips through the peers file")
    func sourceSurvivesARestart() throws {
        let candidates = [candidate("47.206.253.100", .dnsSeed),
                          candidate("74.209.75.75", .fallback),
                          candidate("65.109.145.24", .manual)]
        let data = try JSONEncoder().encode(PersistedPeers(candidates))
        let decoded = try #require(PersistedPeers.decode(data))
        #expect(decoded == candidates)
    }

    @Test("an unreadable peers file is not mistaken for an empty one")
    func garbagePeersFile() {
        #expect(PersistedPeers.decode(Data("not json".utf8)) == nil)
    }

    // MARK: - DNS seed resolver (DoH)

    // DoH dns-json parse, RFC1918/loopback filter, getaddrinfo fallback, and
    // PeerPool wiring. All loopback / fixtures — no live resolver.

    @Test("dns-json A/AAAA parse keeps public IPs and drops RFC1918 on mainnet")
    func parseAndFilterPublic() throws {
        let hosts = try DNSJSON.hosts(from: Vectors.data("doh-a-and-aaaa.json", in: .module))
        #expect(hosts == ["1.2.3.4", "5.6.7.8", "10.0.0.1", "192.168.1.9", "2001:db8::1"])

        let publicNets = SeedResolver.endpoints(hosts: hosts, port: 8333, allowPrivate: false)
        #expect(Set(publicNets.map(\.host)) == ["1.2.3.4", "5.6.7.8", "2001:db8::1"])
        #expect(publicNets.allSatisfy { $0.port == 8333 })

        let custom = SeedResolver.endpoints(hosts: hosts, port: 38_333, allowPrivate: true)
        #expect(Set(custom.map(\.host)) == Set(hosts))
    }

    @Test("CNAME rows are ignored; the following A is kept")
    func cnameThenA() throws {
        let hosts = try DNSJSON.hosts(from: Vectors.data("doh-cname-then-a.json", in: .module))
        #expect(hosts == ["9.9.9.9"])
    }

    @Test("non-zero dns-json Status yields no hosts")
    func servfail() throws {
        #expect(try DNSJSON.hosts(from: Vectors.data("doh-servfail.json", in: .module)).isEmpty)
    }

    @Test("RFC1918-only DoH answers fall back to getaddrinfo on public nets")
    func poisonedDoHFallsBack() async {
        let fixture = try! Vectors.data("doh-rfc1918-only.json", in: .module)
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
        let fixture = try! Vectors.data("doh-rfc1918-only.json", in: .module)
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

    // MARK: - Fallback peer list

    /// Always-on validation of the committed fallback list (#161).
    ///
    /// The generator, `winnow-generate fallback-peers`, runs only on the release
    /// path; this runs on every CI pass, so a hand edit that breaks the list's invariants fails immediately
    /// rather than at the next release.
    @Test("the committed mainnet list holds the generator's own invariants")
    func committedListIsValid() throws {
        let peers = NetworkParams.mainnet.fallbackPeers
        #expect(peers.count >= 8, "shorter than the hand-curated list it replaced")

        var seenBlocks: Set<String> = []
        var seenHosts: Set<String> = []
        for peer in peers {
            // IP literals only: a hostname would add a resolver to the trust
            // story, and `netblock` is nil for hostnames — which doubles as
            // the literal check.
            let block = try #require(peer.netblock,
                                     "\(peer.host) is not a public IP literal")
            #expect(!seenBlocks.contains(block),
                    "\(peer.host) shares a netblock with an earlier entry")
            #expect(!seenHosts.contains(peer.host), "\(peer.host) is listed twice")
            seenBlocks.insert(block)
            seenHosts.insert(peer.host)
            #expect(peer.port == 8_333)
        }
    }

    /// A refresh replaces the addresses; it must not quietly replace what they
    /// count as.
    ///
    /// These endpoints are the `fallback` class wherever they are seen: the
    /// pool classes them so when it builds candidates, and version 2 of the
    /// peers file keeps that class after a successful dial rather than
    /// collapsing them to `persisted`. The source ceiling is what that buys —
    /// however long the list grows, and however fast its peers answer, it
    /// cannot fill a three-slot pool on its own. A list that lost its class
    /// would still pass every shape check above and take the ceiling with it.
    @Test("the committed list keeps the fallback class, and cannot fill the pool alone")
    func committedListKeepsItsSourceClass() throws {
        let candidates = NetworkParams.mainnet.fallbackPeers.map {
            PeerCandidate(endpoint: $0, source: .fallback)
        }
        let encoded = try JSONEncoder().encode(PersistedPeers(candidates))
        let restored = try #require(PersistedPeers.decode(encoded))
        #expect(restored == candidates)
        #expect(restored.allSatisfy { $0.source == .fallback })

        var seated: [PeerCandidate] = []
        for candidate in restored where policy().admits(candidate, given: seated) {
            seated.append(candidate)
        }
        #expect(seated.count == 2, "a list this long must still leave the third slot elsewhere")
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
