import Foundation
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// Fixed 16-byte entropies: the all-"abandon" BIP39 vector, then three that are
/// nothing like it, so an accidental dependence on one low-entropy seed would
/// show up as one failing case rather than none.
private let accountCustodyEntropies: [Data] = [
    testEntropy,
    Data((0 ..< 16).map { UInt8($0) }),
    Data(repeating: 0xAB, count: 16),
    Data([0xF1, 0x02, 0x9C, 0x44, 0x00, 0xFF, 0x7E, 0x13,
          0x8A, 0x55, 0x21, 0xCE, 0x90, 0x0D, 0xB6, 0x37]),
]

/// The differential witness for this fork's account custody: a wallet holding
/// only m/86'/coin'/account' must be indistinguishable, byte for byte, from the
/// wallet upstream builds when it holds the root secret for the same seed.
///
/// Every fact a spend rests on is compared rather than sampled — the wallet ID,
/// the descriptor, each address, the tweaked signing key, a signature over a
/// fixed sighash, and the PSBT key-origin metadata a hardware signer would read.
/// If any of them moved, the account key would be deriving a different chain and
/// the wallet would still look healthy right up to a rejected transaction.
@Suite("Account-key custody")
struct AccountKeyCustodyTests {
    /// Receive and change, first, second, and past the gap limit.
    static let coordinates: [(chain: AddressChain, index: UInt32)] = [
        (.receive, 0), (.receive, 1), (.receive, 21), (.change, 0), (.change, 9),
    ]

    /// One seed, held two ways: upstream's wallet with the mnemonic in its
    /// KeyStore, and this fork's with only the account key and the master
    /// fingerprint. The account key is derived here the way an embedder's own
    /// key service would, and the seed never reaches the second wallet.
    static func bothCustodies(entropy: Data, network: BitcoinNetwork = .signet,
                              creationHeight: UInt32 = 100)
        throws -> (root: Wallet, account: Wallet, rootStore: CountingKeyStore,
                   accountStore: CountingKeyStore) {
        let rootStore = CountingKeyStore()
        let root = try Wallet.create(network: network, keyStore: rootStore,
                                     entropy: entropy, creationHeight: creationHeight)
        let master = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: entropy)))
        let accountKey = try BIP86.accountKey(from: master,
                                              coinType: Wallet.coinType(for: network), account: 0)
        let accountStore = CountingKeyStore()
        let account = try Wallet.create(accountKey: accountKey, masterFingerprint: master.fingerprint,
                                        network: network, keyStore: accountStore,
                                        creationHeight: creationHeight)
        return (root, account, rootStore, accountStore)
    }

    /// A signature over one fixed sighash: fixed spent output, fixed spending
    /// transaction, fixed auxiliary randomness. BIP340 is deterministic given
    /// those, so two equal signatures mean two equal keys — and an unequal pair
    /// says which coordinate drifted.
    static func fixedSighashSignature(secret: Data, scriptPubKey: Data) throws -> Data {
        let witness = try Signer.witness(tx: fixedSpend, inputIndex: 0,
                                         spentOutputs: [fixedSpentOutput(scriptPubKey: scriptPubKey)],
                                         tweakedPrivateKey: secret,
                                         auxiliaryRand: Data(repeating: 0, count: 32))
        return witness[0]
    }

    static func fixedSpentOutput(scriptPubKey: Data) -> SighashBIP341.SpentOutput {
        SighashBIP341.SpentOutput(amount: 100_000, scriptPubKey: scriptPubKey)
    }

    static let fixedSpend = Transaction(
        version: 2,
        inputs: [Transaction.Input(
            previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x11, count: 32), vout: 0),
            scriptSig: Data(), sequence: TransactionBuilder.defaultSequence)],
        outputs: [Transaction.Output(value: 90_000, scriptPubKey: TestScripts.p2trDestination)],
        locktime: 0)

    @Test("account custody derives the same wallet, addresses, keys and signatures as the root",
          arguments: accountCustodyEntropies)
    func differentialWitness(entropy: Data) async throws {
        let (root, account, _, _) = try Self.bothCustodies(entropy: entropy)

        // Identity: the wallet ID is the master fingerprint either way, and the
        // descriptor it is read from is the same string.
        #expect(await root.id == account.id)
        #expect(await root.descriptor.serialized() == account.descriptor.serialized())
        #expect(await root.accountKey == account.accountKey)

        for (chain, index) in Self.coordinates {
            let address = try await root.address(chain: chain, index: index)
            #expect(try await account.address(chain: chain, index: index) == address)
            let script = try await root.scriptPubKey(chain: chain, index: index)
            #expect(try await account.scriptPubKey(chain: chain, index: index) == script)

            // The signing key itself, then a signature made with it. The key
            // comparison localises a failure; the signature is the property
            // that actually spends the coin.
            let rootSecret = try await root.keyPathSecret(chain: chain, index: index)
            let accountSecret = try await account.keyPathSecret(chain: chain, index: index)
            #expect(rootSecret == accountSecret, "key at \(chain)/\(index)")

            let rootSignature = try Self.fixedSighashSignature(secret: rootSecret, scriptPubKey: script)
            let accountSignature = try Self.fixedSighashSignature(secret: accountSecret,
                                                                  scriptPubKey: script)
            #expect(rootSignature == accountSignature, "signature at \(chain)/\(index)")

            // Not two matching wrong answers: the signature verifies against
            // the output key the wallet's own scriptPubKey commits to.
            let sighash = try SighashBIP341.sighash(
                tx: Self.fixedSpend, inputIndex: 0,
                spentOutputs: [Self.fixedSpentOutput(scriptPubKey: script)], hashType: .default)
            var message = [UInt8](sighash)
            let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: script.suffix(32))
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: accountSignature)
            #expect(outputKey.isValid(signature, for: &message), "signature at \(chain)/\(index)")
        }
    }

    @Test("a send under account custody builds the same transaction and the same PSBT origins")
    func differentialSend() async throws {
        let (root, account, rootStore, accountStore) = try Self.bothCustodies(entropy: testEntropy)
        for wallet in [root, account] {
            try await fund(wallet, amount: 500_000, height: 100)
            try await fund(wallet, amount: 250_000, height: 101, chain: .receive, index: 1)
            try await matureCoinbase(wallet, height: 101)
        }
        let rootLoads = rootStore.loads
        let accountLoads = accountStore.loads

        // 600_000 out of a 500_000 and a 250_000 coin: two inputs and a change
        // output, so the comparison covers a change origin as well as spends.
        let payment = [Payment(amount: 600_000, scriptPubKey: TestScripts.p2trDestination)]
        let fromRoot = try await root.buildSend(payments: payment, feeRateSatPerVByte: 2,
                                                chainTip: testChainTip, randomness: { 0.5 })
        let fromAccount = try await account.buildSend(payments: payment, feeRateSatPerVByte: 2,
                                                      chainTip: testChainTip, randomness: { 0.5 })

        // Everything the custody shape controls is byte-identical: the same
        // coins spent in the same order, the same outputs, the same locktime,
        // the same change. Two things here are deliberately not compared as
        // ordered bytes — the witnesses, because BIP340 auxiliary randomness is
        // fresh per signature (`differentialWitness` pins those bytes with it
        // held fixed), and the change output's slot, which
        // `TransactionBuilder.build` draws from its own generator rather than
        // from `randomness`, so change is not always last.
        var unsignedFromRoot = fromRoot.built.transaction
        var unsignedFromAccount = fromAccount.built.transaction
        for index in unsignedFromRoot.inputs.indices { unsignedFromRoot.inputs[index].witness = [] }
        for index in unsignedFromAccount.inputs.indices { unsignedFromAccount.inputs[index].witness = [] }
        #expect(unsignedFromRoot.inputs == unsignedFromAccount.inputs)
        #expect(unsignedFromRoot.inputs.count == 2)
        #expect(unsignedFromRoot.version == unsignedFromAccount.version)
        #expect(unsignedFromRoot.locktime == unsignedFromAccount.locktime)
        #expect(unsignedFromRoot.outputs.sorted { $0.scriptPubKey.hex < $1.scriptPubKey.hex }
            == unsignedFromAccount.outputs.sorted { $0.scriptPubKey.hex < $1.scriptPubKey.hex })
        #expect(fromRoot.built.changeAmount == fromAccount.built.changeAmount)

        // The key origins a hardware signer reads: master fingerprint and full
        // path, on every input and on the change output.
        for (rootInput, accountInput) in zip(fromRoot.built.psbt.inputs, fromAccount.built.psbt.inputs) {
            #expect(rootInput.tapInternalKey == accountInput.tapInternalKey)
            #expect(rootInput.tapBIP32Derivation == accountInput.tapBIP32Derivation)
            let origin = try #require(rootInput.tapBIP32Derivation.values.first)
            #expect(origin.masterFingerprint == UInt32(await root.id, radix: 16))
            #expect(origin.path.count == 5)
        }
        // The change output carries the only output-side origin, wherever it
        // landed, and it reads the same under either custody.
        let rootChange = try #require(fromRoot.built.psbt.outputs.first {
            !$0.tapBIP32Derivation.isEmpty
        })
        let accountChange = try #require(fromAccount.built.psbt.outputs.first {
            !$0.tapBIP32Derivation.isEmpty
        })
        #expect(fromRoot.built.psbt.outputs.filter { !$0.tapBIP32Derivation.isEmpty }.count == 1)
        #expect(rootChange.tapInternalKey == accountChange.tapInternalKey)
        #expect(rootChange.tapBIP32Derivation == accountChange.tapBIP32Derivation)

        // Both witnesses verify against the coins being spent.
        for prepared in [fromRoot, fromAccount] {
            let signed = prepared.built.transaction
            let spentOutputs = try prepared.built.psbt.spentOutputs()
            for index in signed.inputs.indices {
                let sighash = try SighashBIP341.sighash(tx: signed, inputIndex: index,
                                                        spentOutputs: spentOutputs, hashType: .default)
                var message = [UInt8](sighash)
                let outputKey = P256K.Schnorr.XonlyKey(
                    dataRepresentation: spentOutputs[index].scriptPubKey.suffix(32))
                let signature = try P256K.Schnorr.SchnorrSignature(
                    dataRepresentation: signed.inputs[index].witness[0])
                #expect(outputKey.isValid(signature, for: &message), "input \(index) must verify")
            }
        }

        // One KeyStore read per send under either custody: account custody adds
        // no read, and skipping the origin walk removes none.
        #expect(rootStore.loads - rootLoads == 1)
        #expect(accountStore.loads - accountLoads == 1)
    }

    @Test("nothing reads a seed the account wallet does not have")
    func noSeedPath() async throws {
        let (root, account, _, accountStore) = try Self.bothCustodies(entropy: testEntropy)
        try await fund(account, amount: 500_000, height: 100)
        try await matureCoinbase(account, height: 100)

        // The whole of what this wallet's KeyStore holds, after a send: one
        // account key. No mnemonic and no root key is anywhere to be read.
        _ = try await account.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        let secret = try accountStore.load(walletID: await account.id)
        guard case let .accountKey(xprv, fingerprint) = secret else {
            Issue.record("account custody stored \(secret)")
            return
        }
        #expect(fingerprint == UInt32(await account.id, radix: 16))
        #expect(try HDKey.deserialize(xprv).depth == 3)

        // And the seed-bearing export refuses rather than inventing one, the
        // way it already refuses a master xprv. The root wallet still exports.
        await #expect(throws: WalletError.mnemonicUnavailable) {
            _ = try await account.exportBundle(includeMnemonic: true)
        }
        #expect(try await root.exportBundle(includeMnemonic: true).mnemonic == testMnemonic)
        // Watch-only export is public material and works either way.
        #expect(try await account.exportBundle().descriptor
            == (try await root.exportBundle().descriptor))
    }

    @Test("an account key that is not this wallet's is refused, not signed with")
    func mismatchedAccountKeyRefused() async throws {
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let store = InMemoryKeyStore()
        let wallet = try Wallet.create(accountKey: accountKey, masterFingerprint: master.fingerprint,
                                       network: .signet, keyStore: store, creationHeight: 100)
        let id = await wallet.id
        let xprv = accountKey.serialized(network: .testnet)

        // A fingerprint that is not the descriptor's. The key would derive
        // perfectly good signatures for another wallet's coins.
        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: xprv, masterFingerprint: master.fingerprint ^ 1), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }

        // A root key filed as an account key: the right fingerprint, the wrong
        // depth. Walking chain/index from it derives m/0/0, not m/86'/1'/0'/0/0.
        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: master.serialized(network: .testnet),
                                    masterFingerprint: master.fingerprint), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }

        // The next account along, under the same master. Right fingerprint,
        // right depth, wrong wallet — and every signature it makes is valid.
        try store.delete(walletID: id)
        let neighbour = try BIP86.accountKey(from: master, coinType: 1, account: 1)
        try store.store(.accountKey(xprv: neighbour.serialized(network: .testnet),
                                    masterFingerprint: master.fingerprint), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }

        // A neutered account key signs nothing.
        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: accountKey.neutered.serialized(network: .testnet),
                                    masterFingerprint: master.fingerprint), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }

        // Restored, the wallet signs again: the refusals above are about the
        // key that was stored, not about a wallet that has become unusable.
        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: xprv, masterFingerprint: master.fingerprint), for: id)
        #expect(try await wallet.keyPathSecret(chain: .receive, index: 0).count == 32)
    }

    @Test("creation refuses a key that is not an account key")
    func creationRefusesNonAccountKeys() throws {
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let neighbour = try BIP86.accountKey(from: master, coinType: 1, account: 1)
        for key in [master, accountKey.neutered, try accountKey.child(at: 0), neighbour] {
            #expect(throws: WalletError.accountKeyMismatch) {
                _ = try Wallet.create(accountKey: key, masterFingerprint: master.fingerprint,
                                      network: .signet, keyStore: InMemoryKeyStore())
            }
        }
        // Nothing was stored on the way out.
        let store = InMemoryKeyStore()
        #expect(throws: WalletError.accountKeyMismatch) {
            _ = try Wallet.create(accountKey: master, masterFingerprint: master.fingerprint,
                                  network: .signet, keyStore: store)
        }
        #expect(throws: KeyStoreError.notFound(walletID: "73c5da0a")) {
            _ = try store.load(walletID: "73c5da0a")
        }
    }
}
