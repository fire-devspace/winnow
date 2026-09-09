import Foundation

/// Bitcoin network identifier. Regtest is omitted intentionally: this client
/// targets mainnet and the public default signet (BIP325).
public enum BitcoinNetwork: String, Sendable, CaseIterable {
    case mainnet
    case signet
    /// [upstream] A private chain on one machine, mined by RPC: what an
    /// end-to-end suite runs against. Never dialled from seeds; peers come
    /// from `PeerPool(manualPeers:)`.
    case regtest

    /// The networks that ship a checkpoint: the ones a phone reads, whose
    /// chains are years deep. Regtest begins at zero on the machine running
    /// it and never ships one, so the tests that hold every shipped
    /// checkpoint to its source iterate this and not `allCases`.
    public static let checkpointed: [BitcoinNetwork] = [.mainnet, .signet]
}

/// Static per-network parameters, sourced from Bitcoin Core's
/// `src/kernel/chainparams.cpp` (v28.0). All hashes are stored in internal
/// (little-endian) byte order — the order they appear on the wire.
public struct NetworkParams: Sendable, Equatable {
    public let network: BitcoinNetwork
    /// 4-byte message-start magic prefixing every frame.
    public let magic: Data
    public let defaultPort: UInt16
    /// Genesis block header fields (used to derive the genesis hash).
    public let genesisTime: UInt32
    public let genesisBits: UInt32
    public let genesisNonce: UInt32
    public let genesisMerkleRoot: Data
    /// Expected genesis block hash (chainparams.cpp assert), for self-checks.
    public let genesisHash: Data
    /// Consensus powLimit (maximum valid target), 32-byte internal byte order.
    public let powLimit: Data
    public let dnsSeeds: [String]
    /// Hardcoded last-resort peers (IP literals, verified filter-serving —
    /// see the per-network value's comment). Dialed alongside the DNS-seed
    /// results so a fresh launch works even when seed results are dead.
    public let fallbackPeers: [PeerEndpoint]

    /// How long a generated `fallbackPeers` list is treated as current, in days.
    ///
    /// The list is a photograph of the network on the day it was taken, so its
    /// age is the property that decides whether it is worth dialling — not its
    /// length, which `PeerPolicyTests` already holds to a floor. Thirty days is
    /// the figure the release gate has always used; it lives here, beside the
    /// list it governs, so the gate, the check command and any consumer read
    /// one number instead of three copies of it.
    ///
    /// Stated as a library property because the release tag is not the only
    /// way this code ships. A consumer that pins a revision never reaches
    /// `scripts/check-release-policy`, and its bundled list ages from the day
    /// it pinned with nothing to say so; `scripts/check-fallback-peer-age`
    /// answers the same question on any cadence, against this ceiling.
    public static let maxFallbackPeerAgeDays = 30

    /// Optional trusted start for header sync (#89). Present where syncing
    /// from genesis is slow enough to matter, which is both public networks;
    /// it stays optional because a custom signet (`customSignet`) and the
    /// synthetic chains the tests mine have no settled height to trust.
    public let checkpoint: Checkpoint?

    /// A header far enough back to be settled, with the cumulative work of
    /// everything before it — the one number that cannot be recomputed from a
    /// chain that does not contain those headers.
    ///
    /// Starting here means trusting these bytes instead of deriving them.
    /// Everything after the checkpoint is validated exactly as before, and the
    /// constant is auditable: sync from genesis and compare.
    public struct Checkpoint: Sendable, Equatable {
        public let height: UInt32
        /// The 80-byte header, serialized.
        public let header: Data
        /// Cumulative chainwork through `height`, big-endian.
        public let chainwork: Data

        public init(height: UInt32, header: Data, chainwork: Data) {
            precondition(header.count == 80 && chainwork.count == 32)
            self.height = height
            self.header = header
            self.chainwork = chainwork
        }
    }

    public init(network: BitcoinNetwork, magic: Data, defaultPort: UInt16,
                genesisTime: UInt32, genesisBits: UInt32, genesisNonce: UInt32,
                genesisMerkleRoot: Data, genesisHash: Data, powLimit: Data,
                dnsSeeds: [String], fallbackPeers: [PeerEndpoint] = [],
                checkpoint: Checkpoint? = nil) {
        self.network = network
        self.magic = magic
        self.defaultPort = defaultPort
        self.genesisTime = genesisTime
        self.genesisBits = genesisBits
        self.genesisNonce = genesisNonce
        self.genesisMerkleRoot = genesisMerkleRoot
        self.genesisHash = genesisHash
        self.powLimit = powLimit
        self.dnsSeeds = dnsSeeds
        self.checkpoint = checkpoint
        self.fallbackPeers = fallbackPeers
    }

    /// Custom BIP325 signets (magic ≠ public signet) may keep RFC1918 /
    /// loopback seed answers — that is how a laptop-hosted signet is reached.
    /// Public networks drop them so a poisoned resolver cannot park the
    /// whole pool on attacker-controlled LAN addresses.
    public var isCustomSignet: Bool {
        network == .signet && magic != Self.signet.magic
    }

    public var allowsPrivateSeedAddresses: Bool { isCustomSignet }

    public static func params(for network: BitcoinNetwork) -> NetworkParams {
        switch network {
        case .mainnet: return .mainnet
        case .signet: return .signet
        case .regtest: return .regtest
        }
    }

    /// Parameters for a custom BIP325 signet. All signets share the default
    /// signet's consensus fields (genesis block, powLimit); what changes with
    /// the challenge is the network magic: the first 4 bytes of
    /// SHA256d(compactSize(length) ‖ challenge) (BIP325, chainparams.cpp
    /// SignetParams). Custom signets have no DNS seeds — peers come from
    /// `PeerPool(manualPeers:)`.
    public static func customSignet(challenge: Data, defaultPort: UInt16 = 38_333) -> NetworkParams {
        precondition(!challenge.isEmpty, "signet challenge must not be empty")
        return NetworkParams(
            network: .signet,
            magic: signetMagic(challenge: challenge),
            defaultPort: defaultPort,
            genesisTime: signet.genesisTime,
            genesisBits: signet.genesisBits,
            genesisNonce: signet.genesisNonce,
            genesisMerkleRoot: signet.genesisMerkleRoot,
            genesisHash: signet.genesisHash,
            powLimit: signet.powLimit,
            dnsSeeds: []
        )
    }

    /// BIP325 network magic for a signet challenge: the first 4 bytes of
    /// SHA256d of the script serialized with its compactSize length prefix.
    /// Yields 0A03CF40 for the default challenge — the public signet magic.
    static func signetMagic(challenge: Data) -> Data {
        var serialized = Data()
        serialized.appendCompactSize(UInt64(challenge.count))
        serialized.append(challenge)
        return Data(SHA256d.hash(serialized).prefix(4))
    }

    /// The default BIP325 signet challenge (2-of-2 multisig script).
    /// The signet network magic is defined as the first 4 bytes of the
    /// SHA256d of this script, serialized with its compactSize length prefix.
    public static let signetChallenge = Data([
        0x51, 0x21, 0x03, 0xad, 0x5e, 0x0e, 0xda, 0xd1, 0x8c, 0xb1, 0xf0, 0xfc,
        0x0d, 0x28, 0xa3, 0xd4, 0xf1, 0xf3, 0xe4, 0x45, 0x64, 0x03, 0x37, 0x48,
        0x9a, 0xbb, 0x10, 0x40, 0x4f, 0x2d, 0x1e, 0x08, 0x6b, 0xe4, 0x30, 0x21,
        0x03, 0x59, 0xef, 0x50, 0x21, 0x96, 0x4f, 0xe2, 0x2d, 0x6f, 0x8e, 0x05,
        0xb2, 0x46, 0x3c, 0x95, 0x40, 0xce, 0x96, 0x88, 0x3f, 0xe3, 0xb2, 0x78,
        0x76, 0x0f, 0x04, 0x8f, 0x51, 0x89, 0xf2, 0xe6, 0xc4, 0x52, 0xae,
    ])

    /// Mainnet genesis merkle root (display hex 4a5e1e4b…deda33b), internal order.
    private static let genesisMerkleRoot = Data([
        0x3b, 0xa3, 0xed, 0xfd, 0x7a, 0x7b, 0x12, 0xb2, 0x7a, 0xc7, 0x2c, 0x3e,
        0x67, 0x76, 0x8f, 0x61, 0x7f, 0xc8, 0x1b, 0xc3, 0x88, 0x8a, 0x51, 0x32,
        0x3a, 0x9f, 0xb8, 0xaa, 0x4b, 0x1e, 0x5e, 0x4a,
    ])

    public static let mainnet = NetworkParams(
        network: .mainnet,
        magic: Data([0xF9, 0xBE, 0xB4, 0xD9]),
        defaultPort: 8333,
        genesisTime: 1_231_006_505,
        genesisBits: 0x1D00_FFFF,
        genesisNonce: 2_083_236_893,
        genesisMerkleRoot: genesisMerkleRoot,
        genesisHash: Data(displayHex: "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"),
        powLimit: Data(displayHex: "00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        dnsSeeds: [
            "seed.bitcoin.sipa.be",
            "dnsseed.bluematt.me",
            "dnsseed.bitcoin.dashjr-list-of-p2p-nodes.us",
            "seed.bitcoin.jonasschnelli.ch",
            "seed.btc.petertodd.net",
            "seed.bitcoin.sprovoost.nl",
            "dnsseed.emzy.de",
            "seed.bitcoin.wiz.biz",
            "seed.mainnet.achownodes.xyz",
        ],
        // Generated at release time rather than curated by hand (#161): a
        // static public list ages from the day it is written, and #159's
        // source ceiling made the bundled class what fills a pool slot on an
        // ordinary launch. See FallbackPeersGenerated.swift for provenance
        // and for what generation deliberately does not claim.
        fallbackPeers: generatedMainnetFallbackPeers,
        // Derived, not asserted. Winnow synced mainnet from genesis on
        // 2026-08-19, proof-of-work-checking every one of the 900,001 headers
        // up to this height, and emitted the three values below. The block hash
        // was then confirmed against three independent mainnet peers, which all
        // returned the same header for height 900,000.
        //
        // Taken from a chain of 963,233 headers whose tip was height 963,232,
        // 000000000000000000016813353d83651497417cc705d1e2caf46a541e81deef.
        //
        // To reproduce, point `scripts/refresh-checkpoint` at a genesis-validated
        // header file: `winnow-debug generate checkpoint` recomputes all three through
        // the same loading path the app uses, prints the lines below ready to
        // paste, and proves a chain started from them agrees with the
        // genesis-rooted chain 2,000 blocks on (Tools/Generate/README.md).
        // Those 2,000 headers are the vector `HeaderChainTests` replays.
        //
        // Note the two hex spellings below are not interchangeable:
        // `Data(hex:)` keeps byte order, `Data(displayHex:)` reverses it. The
        // header is wire bytes and the chainwork is big-endian, so both take
        // `hex:`; using `displayHex:` for the work would store it backwards and
        // every fork-choice comparison against it would be meaningless.
        //
        // Block 900,000 hash, display order:
        //   000000000000000000010538edbfd2d5b809a33dd83f284aeea41c6d0d96968a
        checkpoint: Checkpoint(
            height: 900_000,
            header: Data(hex:
                "00a0ab20247d4d9f582f9750344cdf62c46d81d046be9603409601000000000000000000"
                + "70f96945530651135839d8adc3f40e595118ec74c7ad81a3d17bb022e554fb0c"
                + "937f4268743702177ad05f92")!,
            chainwork: Data(hex:
                "0000000000000000000000000000000000000000c8bbeae4127a204b0317861c")!
        )
    )

    /// Regtest, as Core's `chainparams.cpp` defines it: the genesis block
    /// shares mainnet's merkle root, its own time, bits and nonce, the
    /// lowest possible difficulty, and no seeds of any kind.
    public static let regtest = NetworkParams(
        network: .regtest,
        magic: Data([0xFA, 0xBF, 0xB5, 0xDA]),
        defaultPort: 18_444,
        genesisTime: 1_296_688_602,
        genesisBits: 0x207F_FFFF,
        genesisNonce: 2,
        genesisMerkleRoot: genesisMerkleRoot,
        genesisHash: Data(displayHex: "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"),
        powLimit: Data(displayHex: "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        dnsSeeds: []
    )

    public static let signet = NetworkParams(
        network: .signet,
        magic: Data([0x0A, 0x03, 0xCF, 0x40]),
        defaultPort: 38333,
        genesisTime: 1_598_918_400,
        genesisBits: 0x1E03_77AE,
        genesisNonce: 52_613_770,
        genesisMerkleRoot: genesisMerkleRoot,
        genesisHash: Data(displayHex: "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6"),
        powLimit: Data(displayHex: "00000377ae000000000000000000000000000000000000000000000000000000"),
        dnsSeeds: [
            "seed.signet.bitcoin.sprovoost.nl",
            "seed.signet.achownodes.xyz",
        ],
        // Derived the same way mainnet's is, by the same command: the file was
        // loaded through HeaderChain, which proof-of-work-checked all 300,001
        // headers up to this height, and `winnow-debug generate checkpoint
        // --network signet` printed the three values below and proved a chain
        // started from them agrees with the genesis-rooted chain 2,000 blocks
        // on. Those 2,000 headers are the vector `HeaderChainTests` replays.
        //
        // Taken from a chain of 302,010 headers whose tip was height 302,009,
        // 000000028b5b3b05bd7ab8dbdce034b2cbaabfc9cee31f5f48d88f1464a814bf.
        // The signet tip that day, 2026-09-08, was 321,267.
        //
        // Where the header file came from, plainly, because it is not the
        // mainnet story. The machine that derived this had no route to port
        // 38333, so the chain was not synced over P2P. Each block's header
        // fields were read from four independent public signet explorers
        // (mempool.space, mempool.emzy.de, explorer.bc-2.jp, mempool.ninja),
        // re-serialized locally, hashed, and required to equal the block id
        // that explorer reported and to link to its parent; this block's 80
        // bytes and hash were then confirmed identical at all four. On a
        // machine with signet peers, `winnow-debug soak --network signet
        // --state DIR` writes the genesis-rooted headers.bin that
        // `scripts/refresh-checkpoint --network signet` wants, and that is the
        // way to reproduce this rather than trust the paragraph above.
        //
        // Say the limit out loud: signet proof of work is trivially cheap and
        // a signet block's signature lives in the coinbase, not in the header,
        // so header validation alone cannot authenticate a signet chain the
        // way it authenticates mainnet's. Agreement across four independent
        // sources is what stands behind these bytes.
        //
        // Block 300,000 hash, display order:
        //   000000073002e4e1de008de89ee41db4baf8734c0f4e5ba9447bb0f1a301b02c
        checkpoint: Checkpoint(
            height: 300_000,
            header: Data(hex:
                "0000002091895bf82cf71598c30ca977cdc36d73a7c7428481bff79d6f24341707000000"
                + "1991de83deadae180910d84541571e875d691e82d97418fff93755fb03ce1317"
                + "5aaedd69df43151d01b5ce04")!,
            chainwork: Data(hex:
                "00000000000000000000000000000000000000000000000000000c88cd095e60")!
        )
    )
}

extension Data {
    /// Interprets a display-order (big-endian) hex hash as internal byte order.
    init(displayHex: String) {
        var bytes = Data()
        bytes.reserveCapacity(displayHex.count / 2)
        var index = displayHex.startIndex
        while index < displayHex.endIndex {
            let next = displayHex.index(index, offsetBy: 2)
            bytes.append(UInt8(displayHex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes.reversed())
    }

    /// Internal-order hash rendered as display-order hex.
    public var displayHex: String {
        reversed().map { String(format: "%02x", $0) }.joined()
    }
}
