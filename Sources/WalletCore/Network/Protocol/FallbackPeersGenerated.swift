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
// Generation: 2026-09-10T05:27:49Z, 38 peers verified, median reported
// tip 966309.
extension NetworkParams {
    static let generatedMainnetFallbackPeers: [PeerEndpoint] = [
        PeerEndpoint(host: "1.156.129.110", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "103.193.138.6", port: 8333),  // /Satoshi:29.3.0/Knots:20260507/
        PeerEndpoint(host: "12.11.29.34", port: 8333),  // /Satoshi:31.99.0/
        PeerEndpoint(host: "124.122.38.63", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "136.50.236.173", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "149.112.12.106", port: 8333),  // /btcwire:0.5.0/btcd:0.26.0/
        PeerEndpoint(host: "173.172.143.161", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "176.129.251.96", port: 8333),  // /Satoshi:29.3.0/Knots:20260507/
        PeerEndpoint(host: "180.148.96.148", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "190.202.186.119", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "195.180.62.206", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "2.4.162.244", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "2001:1600:18:209::385", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "2001:e68:542c:1c3a:7270:fcff:fe05:3cd", port: 8333),  // /Satoshi:29.3.0/
        PeerEndpoint(host: "23.95.114.106", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "24.47.111.152", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "2600:1f1e:2fe:3600:780a:4a97:ff2a:3c7e", port: 8333),  // /Satoshi:29.1.0/
        PeerEndpoint(host: "2804:5268:13b:b200:6d55:a9ca:cc7:8463", port: 8333),  // /Satoshi:29.3.0/Knots:20260210/
        PeerEndpoint(host: "2a02:8308:8188:5100:3bd2:cf60:5f5:9249", port: 8333),  // /Satoshi:29.3.0/
        PeerEndpoint(host: "2a02:c206:3012:8083::1", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "37.191.18.168", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "42.3.180.42", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "49.228.63.128", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "5.193.147.22", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "5.255.98.78", port: 8333),  // /Satoshi:28.3.0/
        PeerEndpoint(host: "50.225.105.5", port: 8333),  // /Satoshi:29.3.0/Knots:20260507/
        PeerEndpoint(host: "54.38.212.14", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "65.109.99.229", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "67.187.86.250", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "81.183.143.40", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "81.213.76.246", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "83.50.188.180", port: 8333),  // /Satoshi:31.0.0/
        PeerEndpoint(host: "86.200.177.42", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "87.236.195.198", port: 8333),  // /Satoshi:30.99.0/
        PeerEndpoint(host: "95.17.238.147", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "98.164.117.96", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "98.73.172.33", port: 8333),  // /Satoshi:31.1.0/
        PeerEndpoint(host: "99.59.251.69", port: 8333),  // /Satoshi:29.3.0/Knots:20260507/
    ]
}
