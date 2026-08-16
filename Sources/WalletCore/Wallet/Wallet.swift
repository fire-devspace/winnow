import BitcoinCore
import BitcoinP2P
import Foundation

public enum WalletError: Error, Equatable, LocalizedError {
    /// Descriptor isn't the wallet's single-sig form: tr(KEY) with a ranged
    /// BIP389 `<0;1>/*` derivation and origin info (see `Wallet.descriptor`).
    case invalidDescriptor(String)
    /// Bundle descriptor does not match the one derived from its mnemonic.
    case descriptorMismatch
    case invalidBundle(String)
    case noPayments
    /// The built transaction lost its change output (should not happen).
    case changeOutputMissing
    /// A seed-bearing export was requested, but the secret is an xprv (or
    /// missing) rather than a BIP39 mnemonic. Refusing is safer than emitting
    /// a bundle that looks spendable and is not.
    case mnemonicUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidDescriptor(text):
            "Invalid descriptor: \(text)"
        case .descriptorMismatch:
            "Bundle descriptor does not match the mnemonic."
        case let .invalidBundle(reason):
            "Invalid import bundle: \(reason)"
        case .noPayments:
            "Nothing to send."
        case .changeOutputMissing:
            "The built transaction lost its change output."
        case .mnemonicUnavailable:
            "This wallet has no recovery phrase to export — it was imported from an extended key, not a BIP39 mnemonic."
        }
    }
}

/// Which chain of the wallet's multipath descriptor an address lives on
/// (BIP44 external/internal).
public enum AddressChain: Int, Codable, Sendable {
    case receive = 0
    case change = 1
}

/// A wallet-controlled unspent output, with the derivation coordinates needed
/// to sign for it.
public struct WalletUTXO: Equatable, Sendable, Codable {
    public var txid: Data // 32 bytes, internal byte order
    public var vout: UInt32
    public var amount: Int64
    public var scriptPubKey: Data
    public var chain: AddressChain
    public var index: UInt32
    /// Block height that confirmed it.
    public var height: UInt32
    /// BIP352: the scalar added to the wallet's silent-payment spend key to
    /// sign for this output (t_k, with any label folded in). It exists only in
    /// scan results, so losing it means a rescan before the output can be
    /// spent. nil for descriptor outputs; when set, `chain`/`index` carry no
    /// meaning.
    public var silentPaymentTweak: Data?

    public init(txid: Data, vout: UInt32, amount: Int64, scriptPubKey: Data,
                chain: AddressChain, index: UInt32, height: UInt32,
                silentPaymentTweak: Data? = nil) {
        self.txid = txid
        self.vout = vout
        self.amount = amount
        self.scriptPubKey = scriptPubKey
        self.chain = chain
        self.index = index
        self.height = height
        self.silentPaymentTweak = silentPaymentTweak
    }

    public var outpoint: Transaction.Outpoint {
        Transaction.Outpoint(txid: txid, vout: vout)
    }

    public var spentOutput: SighashBIP341.SpentOutput {
        SighashBIP341.SpentOutput(amount: amount, scriptPubKey: scriptPubKey)
    }

    // JSON: txid display hex, scriptPubKey hex (human-inspectable state file).
    private enum CodingKeys: String, CodingKey {
        case txid, vout, amount, scriptPubKey, chain, index, height, silentPaymentTweak
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let txid = Data(hex: try container.decode(String.self, forKey: .txid)) else {
            throw DecodingError.dataCorruptedError(forKey: .txid, in: container,
                                                   debugDescription: "bad txid hex")
        }
        guard let scriptPubKey = Data(hex: try container.decode(String.self, forKey: .scriptPubKey)) else {
            throw DecodingError.dataCorruptedError(forKey: .scriptPubKey, in: container,
                                                   debugDescription: "bad scriptPubKey hex")
        }
        var tweak: Data?
        if let tweakHex = try container.decodeIfPresent(String.self, forKey: .silentPaymentTweak) {
            guard let decoded = Data(hex: tweakHex) else {
                throw DecodingError.dataCorruptedError(forKey: .silentPaymentTweak, in: container,
                                                       debugDescription: "bad silentPaymentTweak hex")
            }
            tweak = decoded
        }
        self.init(txid: Data(txid.reversed()),
                  vout: try container.decode(UInt32.self, forKey: .vout),
                  amount: try container.decode(Int64.self, forKey: .amount),
                  scriptPubKey: scriptPubKey,
                  chain: try container.decode(AddressChain.self, forKey: .chain),
                  index: try container.decode(UInt32.self, forKey: .index),
                  height: try container.decode(UInt32.self, forKey: .height),
                  silentPaymentTweak: tweak)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(txid.displayHex, forKey: .txid)
        try container.encode(vout, forKey: .vout)
        try container.encode(amount, forKey: .amount)
        try container.encode(scriptPubKey.hex, forKey: .scriptPubKey)
        try container.encode(chain, forKey: .chain)
        try container.encode(index, forKey: .index)
        try container.encode(height, forKey: .height)
        // Absent for descriptor outputs, so pre-SP state files stay identical.
        try container.encodeIfPresent(silentPaymentTweak?.hex, forKey: .silentPaymentTweak)
    }
}

/// One line of wallet history: a transaction that paid us and/or spent ours.
public struct HistoryEntry: Equatable, Sendable, Codable {
    public var txid: Data // internal byte order; JSON as display hex
    public var height: UInt32
    /// Total received to our scripts by this tx.
    public var received: Int64
    /// Total of ours spent by this tx.
    public var spent: Int64
    /// Fee paid — known only when every input was ours.
    public var fee: Int64?

    public init(txid: Data, height: UInt32, received: Int64, spent: Int64, fee: Int64? = nil) {
        self.txid = txid
        self.height = height
        self.received = received
        self.spent = spent
        self.fee = fee
    }

    private enum CodingKeys: String, CodingKey { case txid, height, received, spent, fee }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let txid = Data(hex: try container.decode(String.self, forKey: .txid)) else {
            throw DecodingError.dataCorruptedError(forKey: .txid, in: container,
                                                   debugDescription: "bad txid hex")
        }
        self.init(txid: Data(txid.reversed()),
                  height: try container.decode(UInt32.self, forKey: .height),
                  received: try container.decode(Int64.self, forKey: .received),
                  spent: try container.decode(Int64.self, forKey: .spent),
                  fee: try container.decodeIfPresent(Int64.self, forKey: .fee))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(txid.displayHex, forKey: .txid)
        try container.encode(height, forKey: .height)
        try container.encode(received, forKey: .received)
        try container.encode(spent, forKey: .spent)
        try container.encodeIfPresent(fee, forKey: .fee)
    }
}

/// What applying one matched block changed (drives import verification).
public struct MatchEffect: Equatable, Sendable {
    public struct Spend: Equatable, Sendable {
        public var txid: Data // spent UTXO's txid
        public var vout: UInt32
        public var spentBy: Data // spending txid
        public var height: UInt32

        public init(txid: Data, vout: UInt32, spentBy: Data, height: UInt32) {
            self.txid = txid
            self.vout = vout
            self.spentBy = spentBy
            self.height = height
        }
    }

    public var received: [WalletUTXO] = []
    public var spent: [Spend] = []

    public init(received: [WalletUTXO] = [], spent: [Spend] = []) {
        self.received = received
        self.spent = spent
    }
}

/// The persisted wallet state (JSON at `storageURL`).
public struct WalletState: Codable, Equatable, Sendable {
    public var descriptor: String
    public var network: String
    public var creationHeight: UInt32
    public var nextReceiveIndex: UInt32
    public var nextChangeIndex: UInt32
    /// Height of the next block whose filter must be scanned (mirrors the
    /// FilterSync progress after the last scan).
    public var nextScanHeight: UInt32
    public var utxos: [WalletUTXO]
    public var history: [HistoryEntry]
    /// Feerate samples (sat/vB) from our own confirmed transactions, newest last.
    public var observedFeeRates: [Double]

    public init(descriptor: String, network: String, creationHeight: UInt32,
                nextReceiveIndex: UInt32 = 0, nextChangeIndex: UInt32 = 0,
                nextScanHeight: UInt32, utxos: [WalletUTXO] = [],
                history: [HistoryEntry] = [], observedFeeRates: [Double] = []) {
        self.descriptor = descriptor
        self.network = network
        self.creationHeight = creationHeight
        self.nextReceiveIndex = nextReceiveIndex
        self.nextChangeIndex = nextChangeIndex
        self.nextScanHeight = nextScanHeight
        self.utxos = utxos
        self.history = history
        self.observedFeeRates = observedFeeRates
    }
}

/// The result of `Wallet.send`: the signed raw transaction plus its PSBT.
public struct BuiltTransaction: Equatable, Sendable {
    public var psbt: PSBT
    /// Fully signed, ready for TxBroadcaster.
    public var transaction: Transaction
    public var fee: Int64
    public var changeAmount: Int64?

    public init(psbt: PSBT, transaction: Transaction, fee: Int64, changeAmount: Int64?) {
        self.psbt = psbt
        self.transaction = transaction
        self.fee = fee
        self.changeAmount = changeAmount
    }
}

/// The single-sig wallet aggregate (docs/read-side.md: fresh-wallet, forward-
/// only scanning). Keys are BIP86 (m/86'/coin'/account'); the descriptor is
/// the BIP389 multipath form
///
///     tr([MASTERFP/86'/COIN'/0']ACCOUNT_XPUB/<0;1>/*)#checksum
///
/// — one descriptor whose multipath choice 0 is the receive chain and choice 1
/// the change chain (COIN = 0 mainnet, 1 signet/testnet per SLIP-44). The
/// wallet ID is the master key fingerprint (8 hex chars).
///
/// Concurrency: an actor; secrets are only loaded from the KeyStore for the
/// duration of a signing operation, never held in wallet state.
public actor Wallet {
    /// BIP44-style gap limit: how many unused addresses past the last used one
    /// stay on the filter watch list.
    public static let gapLimit: UInt32 = 20

    public let id: String
    public let network: BitcoinNetwork
    public let descriptor: Descriptor
    /// Neutered account key at m/86'/coin'/0' — public material only.
    public let accountKey: HDKey
    private let keyStore: any KeyStore
    private let storageURL: URL?
    private var state: WalletState

    init(network: BitcoinNetwork, descriptor: Descriptor, accountKey: HDKey,
         keyStore: any KeyStore, storageURL: URL?, state: WalletState) throws {
        self.network = network
        self.descriptor = descriptor
        self.accountKey = accountKey
        self.keyStore = keyStore
        self.storageURL = storageURL
        self.state = state
        id = String(format: "%08x", try Self.origin(of: descriptor).fingerprint)
    }

    // MARK: - Creation / opening

    /// Creates a fresh wallet: a new BIP39 mnemonic (12 words from 16 bytes of
    /// entropy) stored in the KeyStore, and an empty state scanning forward
    /// from `creationHeight` (a fresh wallet has no history before it).
    public static func create(network: BitcoinNetwork, keyStore: any KeyStore,
                              storageURL: URL? = nil, entropy: Data? = nil,
                              creationHeight: UInt32 = 0, account: UInt32 = 0) throws -> Wallet {
        let mnemonic = try BIP39.mnemonic(entropy: entropy ?? randomEntropy())
        let master = try HDKey(seed: BIP39.seed(mnemonic: mnemonic))
        let coinType = Self.coinType(for: network)
        let accountKey = try BIP86.accountKey(from: master, coinType: coinType, account: account)
        let origin = Descriptor.KeyOrigin(fingerprint: master.fingerprint,
                                          path: [86, coinType, account].map { $0 + HDKey.hardenedOffset })
        let descriptor = Self.makeDescriptor(accountKey: accountKey, origin: origin, network: network)
        let state = WalletState(descriptor: descriptor.serialized(), network: network.rawValue,
                                creationHeight: creationHeight, nextScanHeight: creationHeight)
        let wallet = try Wallet(network: network, descriptor: descriptor,
                                accountKey: accountKey.neutered, keyStore: keyStore,
                                storageURL: storageURL, state: state)
        try keyStore.store(.mnemonic(mnemonic), for: wallet.id)
        if let storageURL {
            try JSONEncoder().encode(state).write(to: storageURL, options: .atomic)
        }
        return wallet
    }

    /// Re-opens a wallet from its persisted JSON state.
    public static func open(storageURL: URL, keyStore: any KeyStore) throws -> Wallet {
        let data = try Data(contentsOf: storageURL)
        let state = try JSONDecoder().decode(WalletState.self, from: data)
        guard let network = BitcoinNetwork(rawValue: state.network) else {
            throw WalletError.invalidBundle("unknown network \(state.network)")
        }
        let descriptor = try Descriptor(state.descriptor)
        _ = try Self.origin(of: descriptor) // validates the wallet descriptor shape
        // The account key is recoverable from the descriptor's xpub.
        guard case let .tr(.single(key), nil) = descriptor.expression,
              case let .extended(accountKey, _) = key.base
        else { throw WalletError.invalidDescriptor(state.descriptor) }
        return try Wallet(network: network, descriptor: descriptor, accountKey: accountKey.neutered,
                          keyStore: keyStore, storageURL: storageURL, state: state)
    }

    /// Builds the canonical multipath tr() descriptor for an account key.
    static func makeDescriptor(accountKey: HDKey, origin: Descriptor.KeyOrigin,
                               network: BitcoinNetwork) -> Descriptor {
        Descriptor(expression: .tr(.single(Descriptor.SingleKey(
            origin: origin,
            base: .extended(accountKey.neutered, network: hdNetwork(for: network)),
            derivation: Descriptor.Derivation([.multipath([0, 1]), .wildcard(hardened: false)]))), nil))
    }

    /// Validates the wallet descriptor shape and returns its key origin.
    static func origin(of descriptor: Descriptor) throws -> Descriptor.KeyOrigin {
        guard case let .tr(.single(key), nil) = descriptor.expression,
              let origin = key.origin,
              key.derivation.elements == [.multipath([0, 1]), .wildcard(hardened: false)]
        else { throw WalletError.invalidDescriptor("expected tr([fp/86'/c'/a']xpub/<0;1>/*)") }
        return origin
    }

    static func coinType(for network: BitcoinNetwork) -> UInt32 {
        network == .mainnet ? 0 : 1 // SLIP-44: all test networks share 1
    }

    static func hdNetwork(for network: BitcoinNetwork) -> HDKey.Network {
        network == .mainnet ? .mainnet : .testnet
    }

    static func randomEntropy() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
    }

    // MARK: - Addresses

    public var creationHeight: UInt32 { state.creationHeight }
    public var nextScanHeight: UInt32 { state.nextScanHeight }
    public var nextReceiveIndex: UInt32 { state.nextReceiveIndex }
    public var nextChangeIndex: UInt32 { state.nextChangeIndex }
    public var balance: Int64 { state.utxos.reduce(0) { $0 + $1.amount } }
    public var utxos: [WalletUTXO] { state.utxos }
    public var history: [HistoryEntry] { state.history }
    public var observedFeeRates: [Double] { state.observedFeeRates }

    /// scriptPubKey at (chain, index), derived from the multipath descriptor.
    public func scriptPubKey(chain: AddressChain, index: UInt32) throws -> Data {
        try descriptor.derived(index: index, network: Self.hdNetwork(for: network))[chain.rawValue].scriptPubKey
    }

    public func address(chain: AddressChain, index: UInt32) throws -> String {
        try descriptor.derived(index: index, network: Self.hdNetwork(for: network))[chain.rawValue].address
    }

    /// The next unused receive address; marks it used (advances the index).
    public func freshReceiveAddress() throws -> String {
        let address = try address(chain: .receive, index: state.nextReceiveIndex)
        state.nextReceiveIndex += 1
        try persist()
        return address
    }

    /// All watched scriptPubKeys: used indices plus the gap-limit lookahead
    /// on both chains.
    public func watchScripts() throws -> [Data] {
        Array(try watchMap().keys)
    }

    /// Watched scriptPubKey → owning (chain, index).
    private func watchMap() throws -> [Data: (chain: AddressChain, index: UInt32)] {
        var map: [Data: (AddressChain, UInt32)] = [:]
        for chain in [AddressChain.receive, AddressChain.change] {
            let next = chain == .receive ? state.nextReceiveIndex : state.nextChangeIndex
            for index in 0 ..< next + Self.gapLimit {
                map[try scriptPubKey(chain: chain, index: index)] = (chain, index)
            }
        }
        return map
    }

    // MARK: - Scanning

    /// Forward-only filter scan (docs/read-side.md §2.5): matched blocks are
    /// applied to the UTXO set and history; the scan position mirrors into the
    /// persisted state afterwards.
    public func scan(using sync: FilterSync) async throws {
        let scripts = try watchScripts()
        try await sync.sync(watchScripts: scripts) { match in
            try await self.apply(match: match)
        }
        try recordScanHeight(await sync.nextScanHeight)
    }

    /// Mirrors FilterSync's frontier into persisted wallet state.
    ///
    /// `apply(match:)` does not move `nextScanHeight` — only this call (or
    /// `scan(using:)`, which ends in it) does. The live app drives FilterSync
    /// directly and must record after each pass, or `exportBundle()` will
    /// emit the creation/import height while the UI shows the filter actor.
    public func recordScanHeight(_ nextScanHeight: UInt32) throws {
        state.nextScanHeight = nextScanHeight
        try persist()
    }

    /// Consumes one matched block: pays to watched scripts become UTXOs (and
    /// advance gap-limit bookkeeping), spends of our UTXOs shrink the set, and
    /// any touching transaction lands in history. Idempotent per block.
    @discardableResult
    public func apply(match: BlockMatch) throws -> MatchEffect {
        let map = try watchMap()
        var effect = MatchEffect()
        for tx in match.block.transactions {
            let txid = tx.txid
            let isCoinbase = tx.inputs.first.map {
                $0.previousOutput.txid == Data(repeating: 0, count: 32)
                    && $0.previousOutput.vout == 0xFFFF_FFFF
            } ?? false
            var spentAmount: Int64 = 0
            var receivedAmount: Int64 = 0
            var allInputsOurs = !isCoinbase && !tx.inputs.isEmpty

            if !isCoinbase {
                for input in tx.inputs {
                    guard let index = state.utxos.firstIndex(where: {
                        $0.txid == input.previousOutput.txid && $0.vout == input.previousOutput.vout
                    }) else {
                        allInputsOurs = false
                        continue
                    }
                    let utxo = state.utxos.remove(at: index)
                    spentAmount += utxo.amount
                    effect.spent.append(MatchEffect.Spend(txid: utxo.txid, vout: utxo.vout,
                                                          spentBy: txid, height: match.height))
                }
            }

            for (vout, output) in tx.outputs.enumerated() {
                guard let (chain, index) = map[output.scriptPubKey] else { continue }
                if let existing = state.utxos.firstIndex(where: { $0.txid == txid && $0.vout == UInt32(vout) }) {
                    // Already known: either a re-applied block, or our own
                    // pending change output being confirmed — update its height.
                    state.utxos[existing].height = match.height
                    continue
                }
                let utxo = WalletUTXO(txid: txid, vout: UInt32(vout), amount: output.value,
                                      scriptPubKey: output.scriptPubKey, chain: chain,
                                      index: index, height: match.height)
                state.utxos.append(utxo)
                receivedAmount += output.value
                effect.received.append(utxo)
                switch chain {
                case .receive where index >= state.nextReceiveIndex:
                    state.nextReceiveIndex = index + 1
                case .change where index >= state.nextChangeIndex:
                    state.nextChangeIndex = index + 1
                default:
                    break
                }
            }

            let touchesWallet = spentAmount > 0 || receivedAmount > 0
                || state.history.contains(where: { $0.txid == txid })
            guard touchesWallet else { continue }

            // Fee + feerate sample: exact only when every input was ours (the
            // BIP341 sighash commits to amounts, so our own sends qualify).
            var fee: Int64? = nil
            if allInputsOurs, spentAmount > 0 {
                let candidate = spentAmount - tx.outputs.reduce(0) { $0 + $1.value }
                if candidate > 0 {
                    fee = candidate
                    let vsize = TransactionBuilder.vsize(of: tx)
                    if vsize > 0 {
                        state.observedFeeRates.append(Double(candidate) / Double(vsize))
                        if state.observedFeeRates.count > 20 { state.observedFeeRates.removeFirst() }
                    }
                }
            }
            if let existing = state.history.firstIndex(where: { $0.txid == txid }) {
                // Known pending send (height 0) reaching confirmation.
                state.history[existing].height = match.height
            } else {
                state.history.append(HistoryEntry(txid: txid, height: match.height,
                                                  received: receivedAmount, spent: spentAmount, fee: fee))
            }
        }
        try persist()
        return effect
    }

    // MARK: - Sending

    /// A fully signed, ready-to-broadcast transaction whose selection has NOT
    /// yet been committed to wallet state. Hand `built.transaction` to the
    /// broadcaster, then call `commit(_:)` — never the other way around.
    public struct PreparedSend: Sendable {
        public let built: BuiltTransaction
        let selected: [WalletUTXO]
        let change: Payment?
        let changeIndex: UInt32
        let fee: Int64
    }

    /// Builds, signs and finalizes a transaction paying `payments` at the given
    /// feerate: coin selection (largest-first, dust-guarded) → unsigned tx →
    /// PSBT creator → per-input key-path signer → finalizer/extractor. The
    /// change output, when any, goes to the next unused internal address.
    ///
    /// `silentPayments` are BIP352 destinations: their P2TR output scripts are
    /// derived after coin selection, when the input set and its keys are known
    /// (BIP352 §Creating outputs), and replace the same-size placeholders used
    /// for fee estimation. Signing stays SIGHASH_DEFAULT — the BIP352-safe
    /// sighash for taproot inputs.
    public func buildSend(payments: [Payment], feeRateSatPerVByte: Double,
                          silentPayments: [SilentPayment] = []) throws -> PreparedSend {
        guard !payments.isEmpty || !silentPayments.isEmpty else { throw WalletError.noPayments }
        let changeIndex = state.nextChangeIndex
        let changeScript = try scriptPubKey(chain: .change, index: changeIndex)
        let sizingPayments = payments + silentPayments.map {
            Payment(amount: $0.amount, scriptPubKey: SilentPayment.sizingScriptPubKey)
        }
        let selection = try CoinSelection.select(utxos: state.utxos, payments: sizingPayments,
                                                 changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRateSatPerVByte)
        // Resolve silent payment outputs: the shared secrets commit to the
        // selected inputs, so derivation happens here — at signing time, with
        // the tweaked input keys in hand. All inputs are our own P2TR key-path
        // spends, which is exactly the BIP352 wallet case.
        var resolvedPayments = payments
        if !silentPayments.isEmpty {
            let inputs = try selection.selected.map { utxo in
                try SilentPaymentSending.Input(txid: utxo.txid, vout: utxo.vout,
                                               prevoutScriptPubKey: utxo.scriptPubKey,
                                               privateKey: keyPathSecret(for: utxo))
            }
            let scripts = try SilentPaymentSending.outputScripts(
                inputs: inputs, recipients: silentPayments.map(\.address))
            resolvedPayments += zip(silentPayments, scripts).map {
                Payment(amount: $0.amount, scriptPubKey: $1)
            }
        }
        let change = selection.changeAmount.map { Payment(amount: $0, scriptPubKey: changeScript) }
        let tx = try TransactionBuilder.build(inputs: selection.selected.map(\.outpoint),
                                              payments: resolvedPayments, change: change)

        let origin = try Self.origin(of: descriptor)
        let inputInfo = try selection.selected.map { utxo -> PSBT.InputInfo in
            // Silent-payment inputs have no BIP86 derivation coordinates to
            // advertise; their key-path secret is b_spend + tweak.
            guard utxo.silentPaymentTweak == nil else {
                return PSBT.InputInfo(spentOutput: utxo.spentOutput, key: nil)
            }
            return try PSBT.InputInfo(spentOutput: utxo.spentOutput,
                                      key: taprootKey(chain: utxo.chain, index: utxo.index,
                                                      fingerprint: origin.fingerprint,
                                                      originPath: origin.path))
        }
        let outputInfo = tx.outputs.map { output -> PSBT.OutputInfo in
            guard let change, output.scriptPubKey == change.scriptPubKey,
                  let key = try? taprootKey(chain: .change, index: changeIndex,
                                            fingerprint: origin.fingerprint, originPath: origin.path)
            else { return PSBT.OutputInfo(key: nil) }
            return PSBT.OutputInfo(key: key)
        }

        var psbt = try PSBT(unsignedTx: tx, inputs: inputInfo, outputs: outputInfo)
        for (index, utxo) in selection.selected.enumerated() {
            try psbt.signKeyPath(input: index, tweakedPrivateKey: keyPathSecret(for: utxo))
        }
        try psbt.finalize()
        let signed = try psbt.extractedTransaction()

        let built = BuiltTransaction(psbt: psbt, transaction: signed, fee: selection.fee,
                                     changeAmount: selection.changeAmount)
        return PreparedSend(built: built, selected: selection.selected, change: change,
                            changeIndex: changeIndex, fee: selection.fee)
    }

    /// Commits a prepared send to wallet state: the spent UTXOs leave the
    /// spendable set at once (so a second send can't double-spend the
    /// unconfirmed tx) and the change output enters it as pending (height 0)
    /// until a block match confirms it and updates the height.
    ///
    /// Call this ONLY after the transaction has been handed to the broadcaster,
    /// never before: committing first means a broadcast that never leaves the
    /// device (no stack, disk error) strands the inputs in a locally-spent but
    /// on-chain-unspent limbo that forward-only scanning cannot repair.
    public func commit(_ prepared: PreparedSend) throws {
        let signed = prepared.built.transaction
        state.utxos.removeAll { utxo in prepared.selected.contains { $0.outpoint == utxo.outpoint } }
        if let change = prepared.change {
            let vout = signed.outputs.firstIndex { $0.scriptPubKey == change.scriptPubKey
                && $0.value == change.amount }
            guard let vout else { throw WalletError.changeOutputMissing }
            state.utxos.append(WalletUTXO(txid: signed.txid, vout: UInt32(vout), amount: change.amount,
                                          scriptPubKey: change.scriptPubKey, chain: .change,
                                          index: prepared.changeIndex, height: 0))
            state.nextChangeIndex += 1
        }
        state.history.append(HistoryEntry(txid: signed.txid, height: 0,
                                          received: prepared.change?.amount ?? 0,
                                          spent: prepared.selected.reduce(0) { $0 + $1.amount },
                                          fee: prepared.fee))
        try persist()
    }

    /// Convenience: build, sign and immediately commit, with no external
    /// broadcast step in between. Prefer `buildSend` → broadcast → `commit`
    /// wherever a broadcaster exists, so a failed broadcast rolls back cleanly.
    @discardableResult
    public func send(payments: [Payment], feeRateSatPerVByte: Double,
                     silentPayments: [SilentPayment] = []) throws -> BuiltTransaction {
        let prepared = try buildSend(payments: payments, feeRateSatPerVByte: feeRateSatPerVByte,
                                     silentPayments: silentPayments)
        try commit(prepared)
        return prepared.built
    }

    // MARK: - Keys

    /// The BIP371 key-origin metadata for one of our addresses: internal key
    /// plus full derivation path from the master fingerprint.
    private func taprootKey(chain: AddressChain, index: UInt32,
                            fingerprint: UInt32, originPath: [UInt32]) throws -> PSBT.TaprootKey {
        let key = try accountKey.child(at: UInt32(chain.rawValue)).child(at: index)
        return PSBT.TaprootKey(internalKey: BIP86.xonlyPublicKey(of: key),
                               masterFingerprint: fingerprint,
                               path: originPath + [UInt32(chain.rawValue), index])
    }

    private static func originUnchecked(of descriptor: Descriptor) -> Descriptor.KeyOrigin {
        guard case let .tr(.single(key), nil) = descriptor.expression, let origin = key.origin else {
            preconditionFailure("wallet descriptor always carries origin info")
        }
        return origin
    }

    /// The master key from the KeyStore — loaded just for the duration of a
    /// derivation or signing call, never held in wallet state.
    private func masterKey() throws -> HDKey {
        switch try keyStore.load(walletID: id) {
        case let .mnemonic(words):
            try HDKey(seed: BIP39.seed(mnemonic: words))
        case let .masterKey(xprv):
            try HDKey.deserialize(xprv)
        }
    }

    /// BIP86 tweaked private key for one of our addresses (key-path spend).
    /// The secret is loaded from the KeyStore just for this call.
    private func tweakedPrivateKey(chain: AddressChain, index: UInt32) throws -> Data {
        let originPath = Self.originUnchecked(of: descriptor).path
        var key = try masterKey()
        for step in originPath { key = try key.child(at: step) }
        key = try key.child(at: UInt32(chain.rawValue)).child(at: index)
        guard let secret = key.privateKey else {
            throw WalletError.invalidDescriptor("neutered key in signing path")
        }
        return try BIP86.tweakedPrivateKey(secret)
    }

    /// The key-path secret that signs for a UTXO: the BIP86 tweaked key for
    /// descriptor outputs, b_spend + tweak for silent-payment outputs (BIP352
    /// outputs carry no TapTweak). Also the correct BIP352 *input* key when
    /// the UTXO funds a silent-payment send — both cases are "the private key
    /// of the taproot output key".
    private func keyPathSecret(for utxo: WalletUTXO) throws -> Data {
        guard let tweak = utxo.silentPaymentTweak else {
            return try tweakedPrivateKey(chain: utxo.chain, index: utxo.index)
        }
        let spend = try SilentPaymentReceiving.spendKey(from: masterKey(),
                                                        coinType: Self.coinType(for: network),
                                                        account: accountIndex)
        guard let secret = spend.privateKey else {
            throw WalletError.invalidDescriptor("neutered key in signing path")
        }
        return try SilentPaymentReceiving.spendSecret(spendPrivateKey: secret, tweak: tweak)
    }

    // MARK: - Silent payments (receive)

    /// The account index from the descriptor origin (m/86'/coin'/account') —
    /// silent payment keys live at the same account under purpose 352'.
    private var accountIndex: UInt32 {
        let path = Self.originUnchecked(of: descriptor).path
        guard path.count == 3 else { return 0 }
        return path[2] - HDKey.hardenedOffset
    }

    /// The wallet's BIP352 silent payment address ("sp1…"/"tsp1…"): B_scan and
    /// B_spend at m/352'/coin'/account'/{1',0'}/0 from the same master seed.
    /// Unlike BIP86 addresses it is static — one address, unlinkable payments.
    public func silentPaymentAddress() throws -> String {
        let master = try masterKey()
        let coinType = Self.coinType(for: network)
        let scan = try SilentPaymentReceiving.scanKey(from: master, coinType: coinType,
                                                      account: accountIndex)
        let spend = try SilentPaymentReceiving.spendKey(from: master, coinType: coinType,
                                                        account: accountIndex)
        return try SilentPaymentAddress(scanKey: scan.publicKey, spendKey: spend.publicKey,
                                        hrp: SilentPayment.hrp(for: network)).encoded
    }

    // MARK: - Export

    /// Live wallet → import bundle. `lastKnownHeight` is the scan frontier
    /// (`nextScanHeight - 1`, or 0 at genesis) so `verifyImport` resumes at
    /// the same height this wallet would scan next. Callers that drive
    /// FilterSync themselves must `recordScanHeight` first — `apply` does
    /// not move the frontier.
    ///
    /// Watch-only by default. The seed is included only on an explicit
    /// opt-in; an xprv-seeded wallet throws ``WalletError/mnemonicUnavailable``
    /// rather than silently exporting a non-spendable "backup".
    public func exportBundle(includeMnemonic: Bool = false) throws -> ImportBundle {
        let lastKnownHeight = state.nextScanHeight == 0 ? 0 : state.nextScanHeight - 1
        let mnemonic: String?
        if includeMnemonic {
            let secret: WalletSecret
            do {
                secret = try keyStore.load(walletID: id)
            } catch let error as KeyStoreError {
                // Missing entry is the same user-facing outcome as an xprv:
                // there is no recovery phrase to put in the file. Don't leak
                // the raw KeyStoreError through the export boundary.
                if case .notFound = error { throw WalletError.mnemonicUnavailable }
                throw error
            }
            switch secret {
            case let .mnemonic(words):
                mnemonic = words
            case .masterKey:
                throw WalletError.mnemonicUnavailable
            }
        } else {
            mnemonic = nil
        }
        return ImportBundle.export(
            descriptor: descriptor.serialized(),
            network: network.rawValue,
            lastKnownHeight: lastKnownHeight,
            utxos: state.utxos,
            history: state.history,
            mnemonic: mnemonic
        )
    }

    // MARK: - Persistence

    func persist() throws {
        guard let storageURL else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: storageURL, options: .atomic)
    }
}
