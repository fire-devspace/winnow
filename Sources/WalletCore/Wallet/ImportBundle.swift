import BitcoinCore
import BitcoinP2P
import Foundation

/// Collects MatchEffects from FilterSync's @Sendable callback.
private final class EffectCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [MatchEffect] = []

    var effects: [MatchEffect] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    func add(_ effect: MatchEffect) {
        lock.lock()
        collected.append(effect)
        lock.unlock()
    }
}

/// A wallet import bundle (docs/import.md): everything the previous
/// wallet software knew — the descriptor and/or mnemonic, the known UTXOs and
/// history, and the last height it scanned — so this wallet can resume by
/// forward-scanning from that height. There is no historical back-scan; the
/// bundle *is* the history.
///
/// JSON format (version 1):
///
///     {
///       "version": 1,
///       "network": "signet",                  // or "mainnet"
///       "descriptor": "tr([fp/86'/1'/0']tpub…/<0;1>/*)#checksum",  // optional w/ mnemonic
///       "mnemonic": "word …",                 // optional w/ descriptor; enables spending
///       "lastKnownHeight": 150000,            // state below is claimed as of this height
///       "utxos": [{ "txid": "<display hex>", "vout": 0, "amount": 50000,
///                   "scriptPubKey": "5120…", "chain": 0, "index": 3, "height": 149000 }],
///       "transactions": [{ "txid": "<display hex>", "height": 149000,
///                          "received": 50000, "spent": 0 }]
///     }
///
/// With both descriptor and mnemonic present they must agree; with only a
/// descriptor the import is watch-only (signing needs the secret). Scanning
/// resumes at `lastKnownHeight + 1`.
public struct ImportBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct UTXO: Codable, Equatable, Sendable {
        public var txid: String // display hex
        public var vout: UInt32
        public var amount: Int64
        public var scriptPubKey: String // hex
        public var chain: Int
        public var index: UInt32
        public var height: UInt32

        public init(txid: String, vout: UInt32, amount: Int64, scriptPubKey: String,
                    chain: Int, index: UInt32, height: UInt32) {
            self.txid = txid
            self.vout = vout
            self.amount = amount
            self.scriptPubKey = scriptPubKey
            self.chain = chain
            self.index = index
            self.height = height
        }
    }

    public struct KnownTransaction: Codable, Equatable, Sendable {
        public var txid: String // display hex
        public var height: UInt32
        public var received: Int64
        public var spent: Int64

        public init(txid: String, height: UInt32, received: Int64, spent: Int64) {
            self.txid = txid
            self.height = height
            self.received = received
            self.spent = spent
        }
    }

    public var version: Int
    public var network: String
    public var descriptor: String?
    public var mnemonic: String?
    public var lastKnownHeight: UInt32
    public var utxos: [UTXO]
    public var transactions: [KnownTransaction]

    public init(version: Int = ImportBundle.currentVersion, network: String,
                descriptor: String? = nil, mnemonic: String? = nil,
                lastKnownHeight: UInt32, utxos: [UTXO] = [], transactions: [KnownTransaction] = []) {
        self.version = version
        self.network = network
        self.descriptor = descriptor
        self.mnemonic = mnemonic
        self.lastKnownHeight = lastKnownHeight
        self.utxos = utxos
        self.transactions = transactions
    }

    /// Writer for the documented v1 schema. Txids go out as display hex —
    /// the same convention `claimedUTXOs()` reverses on the way back in.
    public static func export(descriptor: String, network: String, lastKnownHeight: UInt32,
                              utxos: [WalletUTXO], history: [HistoryEntry],
                              mnemonic: String? = nil) -> ImportBundle {
        ImportBundle(
            network: network,
            descriptor: descriptor,
            mnemonic: mnemonic,
            lastKnownHeight: lastKnownHeight,
            utxos: utxos.map { utxo in
                UTXO(txid: utxo.txid.displayHex, vout: utxo.vout, amount: utxo.amount,
                     scriptPubKey: utxo.scriptPubKey.hex, chain: utxo.chain.rawValue,
                     index: utxo.index, height: utxo.height)
            },
            transactions: history.map { entry in
                KnownTransaction(txid: entry.txid.displayHex, height: entry.height,
                                 received: entry.received, spent: entry.spent)
            }
        )
    }

    /// Pretty-printed, sorted-key JSON ready for a share sheet. Nil optionals
    /// (mnemonic / descriptor) are omitted rather than encoded as `null`.
    public func serialized() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WalletError.invalidBundle("export is not UTF-8")
        }
        return text
    }

    private enum CodingKeys: String, CodingKey {
        case version, network, descriptor, mnemonic, lastKnownHeight, utxos, transactions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(network, forKey: .network)
        try container.encodeIfPresent(descriptor, forKey: .descriptor)
        try container.encodeIfPresent(mnemonic, forKey: .mnemonic)
        try container.encode(lastKnownHeight, forKey: .lastKnownHeight)
        try container.encode(utxos, forKey: .utxos)
        try container.encode(transactions, forKey: .transactions)
    }

    /// The bundle's claimed UTXOs in wallet form.
    public func claimedUTXOs() throws -> [WalletUTXO] {
        try utxos.map { utxo in
            guard let txid = Data(hex: utxo.txid), txid.count == 32 else {
                throw WalletError.invalidBundle("bad txid \(utxo.txid)")
            }
            guard let scriptPubKey = Data(hex: utxo.scriptPubKey) else {
                throw WalletError.invalidBundle("bad scriptPubKey \(utxo.scriptPubKey)")
            }
            guard let chain = AddressChain(rawValue: utxo.chain) else {
                throw WalletError.invalidBundle("bad chain \(utxo.chain)")
            }
            return WalletUTXO(txid: Data(txid.reversed()), vout: utxo.vout, amount: utxo.amount,
                              scriptPubKey: scriptPubKey, chain: chain, index: utxo.index,
                              height: utxo.height)
        }
    }
}

/// The outcome of verifying an import bundle by forward-scanning from its
/// height (docs/import.md §3). Discrepancies surface here, never
/// silently: a bundle that claimed an already-spent UTXO shows up in
/// `spentSinceBundle`.
public struct ImportReport: Equatable, Sendable {
    /// A bundle-claimed UTXO the scan found spent.
    public struct SpentClaim: Equatable, Sendable {
        public var txid: Data
        public var vout: UInt32
        public var spentBy: Data
        public var height: UInt32
    }

    public var scannedFromHeight: UInt32
    public var scannedToHeight: UInt32?
    /// Claimed by the bundle and still unspent after the scan.
    public var confirmedUTXOs: [WalletUTXO]
    /// Claimed by the bundle but spent since — the bundle was stale or wrong.
    public var spentSinceBundle: [SpentClaim]
    /// Found by the scan but absent from the bundle (e.g. payments received
    /// after the bundle was exported). Informational, not a mismatch.
    public var discoveredUTXOs: [WalletUTXO]

    /// The bundle is consistent with the chain as scanned.
    public var matchesBundle: Bool { spentSinceBundle.isEmpty }

    /// Pure verification core (unit-testable without a network): the bundle's
    /// claims against the effects of applying every matched block in
    /// [scannedFromHeight, scannedToHeight].
    public static func make(bundle: ImportBundle, effects: [MatchEffect],
                            finalUTXOs: [WalletUTXO], scannedFromHeight: UInt32,
                            scannedToHeight: UInt32?) throws -> ImportReport {
        let claimed = try bundle.claimedUTXOs()
        let claimedOutpoints = Set(claimed.map { OutpointKey(txid: $0.txid, vout: $0.vout) })

        var spentClaims: [SpentClaim] = []
        for spend in effects.flatMap(\.spent)
        where claimedOutpoints.contains(OutpointKey(txid: spend.txid, vout: spend.vout)) {
            spentClaims.append(SpentClaim(txid: spend.txid, vout: spend.vout,
                                          spentBy: spend.spentBy, height: spend.height))
        }
        let spentKeys = Set(spentClaims.map { OutpointKey(txid: $0.txid, vout: $0.vout) })
        let confirmed = finalUTXOs.filter {
            claimedOutpoints.contains(OutpointKey(txid: $0.txid, vout: $0.vout))
                && !spentKeys.contains(OutpointKey(txid: $0.txid, vout: $0.vout))
        }
        let discovered = effects.flatMap(\.received).filter {
            !claimedOutpoints.contains(OutpointKey(txid: $0.txid, vout: $0.vout))
        }
        return ImportReport(scannedFromHeight: scannedFromHeight, scannedToHeight: scannedToHeight,
                            confirmedUTXOs: confirmed, spentSinceBundle: spentClaims,
                            discoveredUTXOs: discovered)
    }

    private struct OutpointKey: Hashable {
        var txid: Data
        var vout: UInt32
    }
}

extension Wallet {
    /// Seeds a wallet from an import bundle (docs/import.md). The
    /// wallet state starts exactly as the bundle claims; `verifyImport` then
    /// checks those claims against the chain. `creationHeight` becomes the
    /// bundle's `lastKnownHeight` — scanning resumes right after it.
    public static func importing(_ bundle: ImportBundle, keyStore: any KeyStore,
                                 storageURL: URL? = nil) throws -> Wallet {
        guard bundle.version == ImportBundle.currentVersion else {
            throw WalletError.invalidBundle("unsupported version \(bundle.version)")
        }
        guard let network = BitcoinNetwork(rawValue: bundle.network) else {
            throw WalletError.invalidBundle("unknown network \(bundle.network)")
        }
        guard bundle.descriptor != nil || bundle.mnemonic != nil else {
            throw WalletError.invalidBundle("need a descriptor or a mnemonic")
        }

        var descriptor: Descriptor?
        var accountKey: HDKey?
        if let mnemonic = bundle.mnemonic {
            try BIP39.validate(mnemonic: mnemonic)
            let master = try HDKey(seed: BIP39.seed(mnemonic: mnemonic))
            let coinType = Self.coinType(for: network)
            let account = try BIP86.accountKey(from: master, coinType: coinType, account: 0)
            let origin = Descriptor.KeyOrigin(fingerprint: master.fingerprint,
                                              path: [86, coinType, 0].map { $0 + HDKey.hardenedOffset })
            let derived = Self.makeDescriptor(accountKey: account, origin: origin, network: network)
            if let bundleDescriptor = bundle.descriptor,
               try Descriptor(bundleDescriptor) != derived
            {
                throw WalletError.descriptorMismatch
            }
            descriptor = derived
            accountKey = account.neutered
            let walletID = String(format: "%08x", master.fingerprint)
            do {
                try keyStore.store(.mnemonic(mnemonic), for: walletID)
            } catch KeyStoreError.alreadyExists {
                // Re-importing the same secret is fine; a different secret
                // under the same ID (same fingerprint) is not.
                guard try keyStore.load(walletID: walletID) == .mnemonic(mnemonic) else {
                    throw KeyStoreError.alreadyExists(walletID: walletID)
                }
            }
        } else if let bundleDescriptor = bundle.descriptor {
            let parsed = try Descriptor(bundleDescriptor)
            _ = try Self.origin(of: parsed)
            guard case let .tr(.single(key), nil) = parsed.expression,
                  case let .extended(account, _) = key.base
            else { throw WalletError.invalidDescriptor(bundleDescriptor) }
            descriptor = parsed
            accountKey = account.neutered
        }
        guard let descriptor, let accountKey else {
            throw WalletError.invalidBundle("no usable descriptor")
        }

        let utxos = try bundle.claimedUTXOs()
        // Validate claims against the descriptor: every claimed scriptPubKey
        // must be what (chain, index) actually derives to.
        for utxo in utxos {
            let expected = try descriptor
                .derived(index: utxo.index, network: Self.hdNetwork(for: network))[utxo.chain.rawValue]
                .scriptPubKey
            guard expected == utxo.scriptPubKey else {
                throw WalletError.invalidBundle(
                    "utxo \(utxo.txid.displayHex):\(utxo.vout) scriptPubKey does not match the descriptor")
            }
        }

        let history = try bundle.transactions.map { known in
            guard let txid = Data(hex: known.txid), txid.count == 32 else {
                throw WalletError.invalidBundle("bad txid \(known.txid)")
            }
            return HistoryEntry(txid: Data(txid.reversed()), height: known.height,
                                received: known.received, spent: known.spent)
        }

        let state = WalletState(
            descriptor: descriptor.serialized(),
            network: network.rawValue,
            creationHeight: bundle.lastKnownHeight,
            nextReceiveIndex: (utxos.filter { $0.chain == .receive }.map(\.index).max().map { $0 + 1 }) ?? 0,
            nextChangeIndex: (utxos.filter { $0.chain == .change }.map(\.index).max().map { $0 + 1 }) ?? 0,
            nextScanHeight: bundle.lastKnownHeight + 1,
            utxos: utxos,
            history: history
        )
        let wallet = try Wallet(network: network, descriptor: descriptor, accountKey: accountKey,
                                keyStore: keyStore, storageURL: storageURL, state: state)
        if let storageURL {
            try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
        }
        return wallet
    }

    /// Verifies an imported bundle by forward-scanning from its height,
    /// consuming every matched block, and comparing the outcome against the
    /// bundle's claims (docs/import.md §3). Mismatches — e.g. a claimed
    /// UTXO discovered spent — surface in the report, never silently.
    public func verifyImport(_ bundle: ImportBundle, using sync: FilterSync) async throws -> ImportReport {
        let fromHeight = await sync.nextScanHeight
        let collector = EffectCollector()
        try await sync.sync(watchScripts: watchScripts()) { match in
            collector.add(try await self.apply(match: match))
        }
        let toHeight = await sync.lastScannedHeight
        return try ImportReport.make(bundle: bundle, effects: collector.effects, finalUTXOs: utxos,
                                           scannedFromHeight: fromHeight, scannedToHeight: toHeight)
    }
}
