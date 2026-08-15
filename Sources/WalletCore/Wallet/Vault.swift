import BitcoinCore
import BitcoinP2P
import Foundation
import P256K

public enum VaultError: Error, Equatable {
    /// Not a supported vault shape: tr(KEY, multi_a leaf) or tr(musig(...)).
    case invalidDescriptor(String)
    /// The UTXO's scriptPubKey doesn't match the vault descriptor at its coordinates.
    case scriptMismatch(index: UInt32, choice: Int)
    /// None of the cosigner keys for this input derive from the loaded secret.
    case noCosignerKey(input: Int)
}

/// A shared-custody vault: a Taproot output descriptor backing either a
/// **script-path k-of-n** (`tr(INTERNAL, multi_a(k, …))` /
/// `sortedmulti_a`, BIP387) or a **key-path n-of-n** MuSig2 wallet
/// (`tr(musig(k1, k2, …)/0/*)`, BIP390/BIP327).
///
/// For k-of-n vaults the internal key should be one no party can sign with —
/// `Vault.multiADescriptor` uses the BIP341 NUMS point
/// (`Taproot.unspendableInternalKey`), making the script tree the only spend
/// path. Spends run as a PSBTv2 workflow (BIP371/BIP373 fields): the creator
/// builds the spend PSBT, each cosigner partial-signs with the keys it holds,
/// partials are combined, and the finalizer produces the raw transaction.
public struct Vault: Sendable {
    /// The two supported vault policies.
    public enum Policy: Equatable, Sendable {
        /// Script-path k-of-n over a single multi_a/sortedmulti_a leaf.
        case multiA(threshold: Int, sorted: Bool, cosigners: [Descriptor.KeyExpression],
                    internalKey: Descriptor.KeyExpression)
        /// Key-path n-of-n MuSig2 (BIP390 musig() with a BIP328 derivation suffix).
        case muSig2(participants: [Descriptor.SingleKey], derivation: Descriptor.Derivation)
    }

    public let descriptor: Descriptor
    public let network: BitcoinNetwork
    public let policy: Policy

    public init(descriptor: Descriptor, network: BitcoinNetwork) throws {
        switch descriptor.expression {
        case let .tr(internalKey, .some(.leaf(.multiA(threshold, keys)))):
            policy = .multiA(threshold: threshold, sorted: false, cosigners: keys, internalKey: internalKey)
        case let .tr(internalKey, .some(.leaf(.sortedMultiA(threshold, keys)))):
            policy = .multiA(threshold: threshold, sorted: true, cosigners: keys, internalKey: internalKey)
        case let .tr(.musig(participants, derivation), nil):
            policy = .muSig2(participants: participants, derivation: derivation)
        default:
            throw VaultError.invalidDescriptor("expected tr(KEY, multi_a(k, …)) or tr(musig(…)/…)")
        }
        self.descriptor = descriptor
        self.network = network
    }

    public init(_ string: String, network: BitcoinNetwork) throws {
        try self.init(descriptor: Descriptor(string), network: network)
    }

    /// The canonical k-of-n vault descriptor: `tr(NUMS, sortedmulti_a(k, …))`
    /// with the BIP341 NUMS internal key, so no single party can key-path
    /// spend. `cosigners` are key expression texts (e.g. `[fp/86'/1'/0']xpub…/<0;1>/*`).
    public static func multiADescriptor(threshold k: Int, cosigners: [String]) throws -> Descriptor {
        let text = "tr(\(Taproot.unspendableInternalKey.hex),sortedmulti_a(\(k),\(cosigners.joined(separator: ","))))"
        return try Descriptor(text)
    }

    /// Whether the vault uses the BIP341 NUMS point as its internal key.
    public var usesUnspendableInternalKey: Bool {
        guard case let .multiA(_, _, _, internalKey) = policy,
              let key = try? descriptor.publicKey(of: internalKey, index: 0, choice: 0)
        else { return false }
        return Data(key.dropFirst()) == Taproot.unspendableInternalKey
    }

    // MARK: - Watching

    static func hdNetwork(for network: BitcoinNetwork) -> HDKey.Network {
        network == .mainnet ? .mainnet : .testnet
    }

    /// scriptPubKey at (multipath choice, index) — choice 0 receive, 1 change.
    public func scriptPubKey(index: UInt32, choice: Int = 0) throws -> Data {
        try descriptor.derived(index: index, network: Self.hdNetwork(for: network))[choice].scriptPubKey
    }

    public func address(index: UInt32, choice: Int = 0) throws -> String {
        try descriptor.derived(index: index, network: Self.hdNetwork(for: network))[choice].address
    }

    /// The scriptPubKeys to watch: both multipath choices for indices 0..<count.
    public func watchScripts(upTo count: UInt32) throws -> [Data] {
        var scripts: [Data] = []
        for index in 0 ..< count {
            for output in try descriptor.derived(index: index, network: Self.hdNetwork(for: network)) {
                scripts.append(output.scriptPubKey)
            }
        }
        return scripts
    }

    // MARK: - Spending (creator role)

    /// Builds the vault spend PSBT (creator role): coin selection and the
    /// unsigned transaction like `Wallet.send`, then the vault fields — for
    /// multi_a the BIP371 leaf script, control block and per-key origins; for
    /// MuSig2 the BIP373 participant pubkeys and the BIP328-derived internal
    /// key. Change (if any) goes to choice 1 at `changeIndex` and carries
    /// PSBT_OUT_TAP_TREE / internal key so cosigners can verify it belongs to
    /// the vault.
    public func createSpend(utxos: [WalletUTXO], payments: [Payment], changeIndex: UInt32,
                            feeRateSatPerVByte: Double) throws -> PSBT {
        for utxo in utxos {
            guard try scriptPubKey(index: utxo.index, choice: utxo.chain.rawValue) == utxo.scriptPubKey else {
                throw VaultError.scriptMismatch(index: utxo.index, choice: utxo.chain.rawValue)
            }
        }
        let changeScript = try scriptPubKey(index: changeIndex, choice: AddressChain.change.rawValue)
        let selection = try CoinSelection.select(utxos: utxos, payments: payments,
                                                 changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRateSatPerVByte,
                                                 witnessBytesPerInput: witnessBytesPerInput(index: utxos.first?.index ?? 0))
        let change = selection.changeAmount.map { Payment(amount: $0, scriptPubKey: changeScript) }
        let tx = try TransactionBuilder.build(inputs: selection.selected.map(\.outpoint),
                                              payments: payments, change: change)
        var psbt = try PSBT(unsignedTx: tx,
                            inputs: selection.selected.map { PSBT.InputInfo(spentOutput: $0.spentOutput) },
                            outputs: tx.outputs.map { _ in PSBT.OutputInfo() })
        for (index, utxo) in selection.selected.enumerated() {
            try attachVaultFields(&psbt, input: index, choice: utxo.chain.rawValue, index: utxo.index)
        }
        if let change {
            for (outputIndex, output) in tx.outputs.enumerated()
            where output.scriptPubKey == change.scriptPubKey && output.value == change.amount {
                try attachVaultOutputFields(&psbt, output: outputIndex, choice: AddressChain.change.rawValue,
                                            index: changeIndex)
            }
        }
        return psbt
    }

    /// Per-input witness byte count for fee estimation: exact for the vault's
    /// spend shape (BIP387 witness for multi_a, 64-byte sig for MuSig2).
    private func witnessBytesPerInput(index: UInt32) -> Int {
        switch policy {
        case let .multiA(_, _, cosigners, _):
            // 1 (item count) + n sig slots (1 + 64) + script + control block,
            // each var-data length-prefixed; single-leaf tree → 33-byte control.
            let keyCount = cosigners.count
            let leaf = try? descriptor.resolvedTaproot(index: index, choice: 0).tree
            let scriptSize = leaf.map { tree -> Int in
                guard case let .leaf(_, script) = tree else { return 0 }
                return script.bytes.count
            } ?? keyCount * 34 + 2
            return 1 + keyCount * 65 + (1 + scriptSize) + (1 + 33)
        case .muSig2:
            return 66 // count(1) + length(1) + 64-byte aggregate signature
        }
    }

    /// Attaches the vault fields for one spend input at (choice, index).
    private func attachVaultFields(_ psbt: inout PSBT, input: Int, choice: Int, index: UInt32) throws {
        switch policy {
        case .multiA:
            let (internalKey, tree) = try descriptor.resolvedTaproot(index: index, choice: choice)
            guard case let .leaf(version, script) = tree else {
                throw VaultError.invalidDescriptor("multi_a vault must have a single leaf")
            }
            let controlBlock = try Taproot.controlBlock(internalKey: internalKey, tree: tree!, leafIndex: 0)
            // attachScriptPath fills in the leaf hash itself.
            let origins = try keyOrigins(choice: choice, index: index, leafHashes: [])
            try psbt.attachScriptPath(input: input, controlBlock: controlBlock, leafScript: script,
                                      leafVersion: version, keyOrigins: origins)
        case .muSig2:
            let context = try muSig2Context(choice: choice, index: index)
            try psbt.attachMuSig2(input: input, internalKey: context.internalKey,
                                  aggregate: context.aggregate, participants: context.participants)
        }
    }

    /// BIP371 key origins for every multi_a cosigner at (choice, index):
    /// master fingerprint, the full path (origin path plus the derivation
    /// suffix steps taken at (choice, index)) and the leaf hashes the key
    /// participates in. Empty for MuSig2 vaults (no per-key expressions).
    private func keyOrigins(choice: Int, index: UInt32,
                            leafHashes: [Data]) throws -> [Data: PSBT.KeyOrigin] {
        var origins: [Data: PSBT.KeyOrigin] = [:]
        for expression in cosignerKeyExpressions() {
            guard case let .single(single) = expression,
                  let origin = single.origin,
                  case .extended = single.base
            else { continue }
            let compressed = try descriptor.publicKey(of: expression, index: index, choice: choice)
            let suffix = single.derivation.elements.map { element -> UInt32 in
                switch element {
                case let .step(step): return step
                case let .multipath(values): return values[choice]
                case let .wildcard(hardened): return index + (hardened ? HDKey.hardenedOffset : 0)
                }
            }
            origins[Data(compressed.dropFirst())] = PSBT.KeyOrigin(leafHashes: leafHashes,
                                                                   masterFingerprint: origin.fingerprint,
                                                                   path: origin.path + suffix)
        }
        return origins
    }

    /// Change-output fields so cosigners can verify the vault owns the output.
    private func attachVaultOutputFields(_ psbt: inout PSBT, output: Int, choice: Int, index: UInt32) throws {
        let (internalKey, tree) = try descriptor.resolvedTaproot(index: index, choice: choice)
        psbt.outputs[output].tapInternalKey = internalKey
        if let tree {
            // PSBT_OUT_TAP_TREE with the leaf depth(s) — single-leaf vaults: depth 0.
            var tuples: [(depth: UInt8, leafVersion: UInt8, script: Data)] = []
            collectLeaves(tree, depth: 0, into: &tuples)
            psbt.outputs[output].tapTree = tuples
            // PSBT_OUT_TAP_BIP32_DERIVATION for every cosigner — marks the
            // output as the vault's own change (VaultSignView's review reads
            // a non-empty derivation as "Change (this vault)").
            if case .multiA = policy, let tuple = tuples.first, tuples.count == 1 {
                let leafHash = Taproot.leafHash(version: tuple.leafVersion, script: Script(tuple.script))
                psbt.outputs[output].tapBIP32Derivation = try keyOrigins(choice: choice, index: index,
                                                                         leafHashes: [leafHash])
            }
        }
    }

    private func collectLeaves(_ tree: Taproot.Tree, depth: UInt8,
                               into tuples: inout [(depth: UInt8, leafVersion: UInt8, script: Data)]) {
        switch tree {
        case let .leaf(version, script):
            tuples.append((depth, version, script.bytes))
        case let .branch(left, right):
            collectLeaves(left, depth: depth + 1, into: &tuples)
            collectLeaves(right, depth: depth + 1, into: &tuples)
        }
    }

    private func cosignerKeyExpressions() -> [Descriptor.KeyExpression] {
        guard case let .multiA(_, _, cosigners, _) = policy else { return [] }
        return cosigners
    }

    // MARK: - Script-path signing (multi_a)

    /// Partial-signs every input of a multi_a vault spend with whichever
    /// cosigner keys derive from `master` (matched against the BIP371
    /// derivation fingerprints in the PSBT). Throws `noCosignerKey` when an
    /// input has no key we hold. The PSBT then travels (Base64) to the next
    /// cosigner; when k partials are present, combine + finalize.
    public func partialSign(_ psbt: inout PSBT, master: HDKey) throws {
        guard case .multiA = policy else { throw VaultError.invalidDescriptor("not a multi_a vault") }
        for index in psbt.inputs.indices {
            var secrets: [Data] = []
            for (xonly, origin) in psbt.inputs[index].tapBIP32Derivation {
                guard origin.masterFingerprint == master.fingerprint else { continue }
                var key = master
                for step in origin.path { key = try key.child(at: step) }
                guard let secret = key.privateKey,
                      let schnorr = try? P256K.Schnorr.PrivateKey(dataRepresentation: secret),
                      Data(schnorr.xonly.bytes) == xonly
                else { continue }
                secrets.append(secret)
            }
            guard !secrets.isEmpty else { throw VaultError.noCosignerKey(input: index) }
            try psbt.signScriptPath(input: index, privateKeys: secrets)
        }
    }

    // MARK: - MuSig2 signing (n-of-n)

    /// The MuSig2 signing context of a vault input at (choice, index): the
    /// sorted participant keys, the root aggregate key, the BIP328-derived
    /// internal key, and the BIP327 tweak chain (path tweaks as plain tweaks,
    /// then the BIP341 TapTweak as the x-only tweak).
    public struct MuSig2Context: Equatable, Sendable {
        /// The vault coordinates this context was built for.
        public var choice: Int
        public var index: UInt32
        /// Sorted compressed participant keys (aggregation order, BIP390).
        public var participants: [Data]
        /// The root aggregate key (compressed) — the BIP373 field key.
        public var aggregate: Data
        /// The internal key (x-only): root aggregate after the BIP328 path.
        public var internalKey: Data
        /// BIP328 path tweaks followed by the TapTweak hash.
        public var tweaks: [Data]
        /// is_xonly per tweak: false for the path, true for the TapTweak.
        public var isXOnlyTweaks: [Bool]
        /// The final tweaked aggregate key = the vault's output key (x-only).
        public var outputKey: Data
    }

    /// Computes the MuSig2 context for the vault coordinates, cross-checked
    /// against the descriptor's own scriptPubKey derivation.
    public func muSig2Context(choice: Int, index: UInt32) throws -> MuSig2Context {
        guard case let .muSig2(participantKeys, derivation) = policy else {
            throw VaultError.invalidDescriptor("not a musig vault")
        }
        var resolved: [Data] = []
        for participant in participantKeys {
            resolved.append(try descriptor.publicKey(of: .single(participant), index: index, choice: choice))
        }
        let sorted = MuSig.keySort(resolved)
        let aggregate = try MuSig.aggregate(sorted)
        // Walk the BIP328 derivation, collecting each step's plain tweak.
        var synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregate)
        var tweaks: [Data] = []
        var isXOnly: [Bool] = []
        for element in derivation.elements {
            let step: UInt32
            switch element {
            case let .step(value): step = value
            case let .multipath(values): step = values[choice]
            case let .wildcard(hardened):
                guard !hardened else { throw VaultError.invalidDescriptor("hardened musig wildcard") }
                step = index
            }
            tweaks.append(MuSig.bip328Tweak(chainCode: synthetic.chainCode,
                                            aggregatePublicKey: synthetic.publicKey, index: step))
            isXOnly.append(false)
            synthetic = try synthetic.child(at: step)
        }
        let internalKey = Data(synthetic.publicKey.dropFirst())
        // The tr() output key tweak (no script tree in a MuSig2 vault).
        tweaks.append(Taproot.tweak(internalKey: internalKey, merkleRoot: nil))
        isXOnly.append(true)
        let outputKey = try MuSig.aggregateXonly(publicKeys: sorted, tweaks: tweaks, isXOnlyTweaks: isXOnly)
        // Cross-check: the tweaked aggregate must be the descriptor's output key.
        guard try scriptPubKey(index: index, choice: choice) == Data([0x51, 0x20]) + outputKey else {
            throw VaultError.invalidDescriptor("musig tweak chain mismatch")
        }
        return MuSig2Context(choice: choice, index: index, participants: sorted, aggregate: aggregate,
                             internalKey: internalKey, tweaks: tweaks, isXOnlyTweaks: isXOnly,
                             outputKey: outputKey)
    }

    /// The message cosigners sign for a MuSig2 vault input: the BIP341
    /// key-path sighash with the input's hash type.
    public func keyPathSighash(_ psbt: PSBT, input: Int) throws -> Data {
        let rawType = psbt.inputs[input].sighashType ?? 0
        guard rawType <= UInt32(UInt8.max) else { throw PSBTError.malformed("sighash type \(rawType)") }
        let hashType = SighashBIP341.HashType(rawValue: UInt8(rawType))
        // A vault cosigner must never sign a non-output-committing sighash: a
        // malicious PSBT creator could otherwise collect NONE/SINGLE partials
        // and rewrite the outputs to steal the funds.
        guard hashType.commitsToAllOutputs else {
            throw PSBTError.malformed("refusing non-DEFAULT/ALL sighash type \(rawType)")
        }
        return try SighashBIP341.sighash(tx: psbt.unsignedTransaction(), inputIndex: input,
                                         spentOutputs: psbt.spentOutputs(),
                                         hashType: hashType)
    }

    /// MuSig2 round 1: attaches this cosigner's BIP373 public nonce (bound to
    /// the aggregate key and the sighash, per BIP327 NonceGen guidance) and
    /// returns the secret nonces keyed by participant pubkey — the caller MUST
    /// keep them until round 2 and never reuse them.
    public func muSig2AttachNonce(_ psbt: inout PSBT, input: Int, context: MuSig2Context,
                                  master: HDKey, extraInput: Data? = nil) throws -> [Data: Data] {
        let message = try keyPathSighash(psbt, input: input)
        var secretNonces: [Data: Data] = [:] // participant pubkey → secnonce
        for (participant, secret) in try participantSecrets(context: context, master: master) {
            let (secretNonce, publicNonce) = try MuSig.nonceGenerate(
                secretKey: secret, publicKey: participant, aggregateKey: context.outputKey,
                message: message, extraInput: extraInput)
            try psbt.attachMuSig2PubNonce(input: input,
                                          id: PSBT.MuSig2KeyID(participant: participant,
                                                               aggregate: context.aggregate),
                                          nonce: publicNonce)
            secretNonces[participant] = secretNonce
        }
        guard !secretNonces.isEmpty else { throw VaultError.noCosignerKey(input: input) }
        return secretNonces
    }

    /// MuSig2 round 2 (after every cosigner attached a nonce): partial-signs
    /// and attaches PSBT_IN_MUSIG2_PARTIAL_SIG, zeroing the secret nonce.
    public func muSig2Sign(_ psbt: inout PSBT, input: Int, context: MuSig2Context,
                           master: HDKey, secretNonces: inout [Data: Data]) throws {
        let session = try psbt.muSig2Session(input: input, aggregateKey: context.aggregate,
                                             tweaks: context.tweaks, isXOnlyTweaks: context.isXOnlyTweaks,
                                             message: keyPathSighash(psbt, input: input))
        var signed = 0
        for (participant, secret) in try participantSecrets(context: context, master: master) {
            guard var secnonce = secretNonces[participant] else { continue }
            try psbt.signMuSig2(input: input,
                                id: PSBT.MuSig2KeyID(participant: participant, aggregate: context.aggregate),
                                secretNonce: &secnonce, secretKey: secret, session: session)
            secretNonces[participant] = secnonce // zeroed by partialSign
            signed += 1
        }
        guard signed > 0 else { throw VaultError.noCosignerKey(input: input) }
    }

    /// MuSig2 final step: combines the partial signatures into the aggregate
    /// BIP340 signature (PSBT_IN_TAP_KEY_SIG); `finalize()` then produces the
    /// single-item key-path witness.
    public func muSig2Aggregate(_ psbt: inout PSBT, input: Int, context: MuSig2Context) throws {
        let session = try psbt.muSig2Session(input: input, aggregateKey: context.aggregate,
                                             tweaks: context.tweaks, isXOnlyTweaks: context.isXOnlyTweaks,
                                             message: keyPathSighash(psbt, input: input))
        try psbt.aggregateMuSig2(input: input, session: session)
    }

    /// Finalizes the fully-signed PSBT and extracts the raw transaction.
    public func finalizeSpend(_ psbt: inout PSBT) throws -> Transaction {
        try psbt.finalize()
        return try psbt.extractedTransaction()
    }

    // MARK: - Cosigner secrets

    /// (participant compressed pubkey, secret) pairs for every vault
    /// participant derivable from `master` (origin fingerprint match).
    private func participantSecrets(context: MuSig2Context, master: HDKey) throws -> [(Data, Data)] {
        guard case let .muSig2(participantKeys, _) = policy else { return [] }
        var result: [(Data, Data)] = []
        for single in participantKeys {
            guard let secret = try privateKey(for: single, master: master, context: context),
                  let key = try? P256K.Signing.PrivateKey(dataRepresentation: secret)
            else { continue }
            let participant = key.publicKey.dataRepresentation
            if context.participants.contains(participant) { result.append((participant, secret)) }
        }
        return result
    }

    /// Derives a participant/cosigner secret from the master key: along the
    /// origin path, then the key's own derivation suffix at the context's
    /// coordinates. Returns nil when the key isn't from this master.
    private func privateKey(for single: Descriptor.SingleKey, master: HDKey,
                            context: MuSig2Context) throws -> Data? {
        guard let origin = single.origin, origin.fingerprint == master.fingerprint,
              case let .extended(base, _) = single.base
        else { return nil }
        var key = master
        for step in origin.path { key = try key.child(at: step) }
        guard key.publicKey == base.publicKey else { return nil } // origin/base mismatch
        for element in single.derivation.elements {
            switch element {
            case let .step(step): key = try key.child(at: step)
            case let .multipath(values): key = try key.child(at: values[context.choice])
            case let .wildcard(hardened):
                guard !hardened else { return nil }
                key = try key.child(at: context.index)
            }
        }
        return key.privateKey
    }
}
