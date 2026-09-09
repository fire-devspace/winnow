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
                              creationHeight: UInt32 = 100, account: UInt32 = 0)
        throws -> (root: Wallet, account: Wallet, rootStore: CountingKeyStore,
                   accountStore: CountingKeyStore) {
        let rootStore = CountingKeyStore()
        let root = try Wallet.create(network: network, keyStore: rootStore,
                                     entropy: entropy, creationHeight: creationHeight,
                                     account: account)
        let master = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: entropy)))
        let accountKey = try BIP86.accountKey(from: master,
                                              coinType: Wallet.coinType(for: network),
                                              account: account)
        let accountStore = CountingKeyStore()
        let accountWallet = try Wallet.create(accountKey: accountKey,
                                              masterFingerprint: master.fingerprint,
                                              network: network, keyStore: accountStore,
                                              creationHeight: creationHeight, account: account)
        return (root, accountWallet, rootStore, accountStore)
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

    /// Both public networks, because the two things `create(accountKey:)`
    /// computes from the network are the origin path's coin type (0 against 1)
    /// and the xprv/xpub version bytes, and each of them branches on mainnet
    /// against everything else. Signet alone exercised one side of both.
    /// A serialized key can name any depth, including the last one a byte
    /// can hold. Walking below it used to be `depth + 1` on a `UInt8`, which
    /// traps; it is a refusal now, so an import bundle carrying such a key
    /// is an error and not a crash at the first address.
    @Test("a key at depth 255 refuses a child rather than trapping")
    func depthExhausted() throws {
        let master = try testMaster()
        let last = HDKey(depth: 255, parentFingerprint: master.fingerprint, childIndex: 0,
                         chainCode: master.chainCode, privateKey: master.privateKey, publicKey: master.publicKey)
        #expect(throws: BIP32Error.depthExhausted) { _ = try last.child(at: 0) }
        #expect(throws: BIP32Error.depthExhausted) { _ = try last.neutered.child(at: 0) }
        let almost = HDKey(depth: 254, parentFingerprint: master.fingerprint, childIndex: 0,
                           chainCode: master.chainCode, privateKey: master.privateKey, publicKey: master.publicKey)
        #expect(try almost.child(at: 0).depth == 255)
    }

    @Test("account custody derives the same wallet, addresses, keys and signatures as the root",
          arguments: accountCustodyEntropies, [BitcoinNetwork.signet, .mainnet])
    func differentialWitness(entropy: Data, network: BitcoinNetwork) async throws {
        try await Self.compareCustodies(entropy: entropy, network: network, account: 0)
    }

    /// The same witness across account indices, because `account` is the one
    /// number both constructors put into the origin path and neither reads back
    /// from the other. Account 0 alone would let the account constructor ignore
    /// its argument entirely and still agree with the root on every byte.
    ///
    /// 0x7FFF_FFFF is the last account there is: one more sets the hardened bit
    /// the path adds, which is not a deeper account but an argument neither
    /// constructor can honour.
    @Test("account custody agrees with the root at every account index",
          arguments: [UInt32(0), 1, 5, 0x7FFF_FFFF], [BitcoinNetwork.signet, .mainnet])
    func differentialWitnessAcrossAccounts(account: UInt32, network: BitcoinNetwork) async throws {
        try await Self.compareCustodies(entropy: testEntropy, network: network, account: account)
    }

    /// The comparison both witnesses run: every fact a spend rests on, read
    /// off a root-custody wallet and an account-custody one built from the same
    /// seed, network and account index.
    static func compareCustodies(entropy: Data, network: BitcoinNetwork,
                                 account accountIndex: UInt32) async throws {
        let (root, account, _, _) = try Self.bothCustodies(entropy: entropy, network: network,
                                                           account: accountIndex)

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

    /// An account key from another seed entirely, filed under this wallet's
    /// master fingerprint. Depth, child index and private-ness are all things
    /// the stored key says about itself, and a forged fingerprint is one more,
    /// so every self-describing check passes and the key derives a real
    /// 32-byte signing secret for a chain this wallet does not own.
    ///
    /// The descriptor is what knows better: it carries the neutered account
    /// key the addresses come from. Before that term was in the guard, the
    /// mismatch first showed up at `psbt.finalize()` as "input 0 invalid tap
    /// key signature" — the wrong error, two layers down, and only because
    /// finalize self-verifies. `signKeyPath` does not, so a caller that
    /// stopped at a signature got a valid signature for someone else's coins.
    @Test("an account key from another seed is refused however well it describes itself")
    func foreignSeedAccountKeyRefused() async throws {
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let store = InMemoryKeyStore()
        let wallet = try Wallet.create(accountKey: accountKey, masterFingerprint: master.fingerprint,
                                       network: .signet, keyStore: store, creationHeight: 100)
        let id = await wallet.id

        // A different seed, the same path, and this wallet's fingerprint
        // claimed beside it: private, depth 3, child index 0x80000000.
        let foreign = try HDKey(seed: BIP39.seed(
            mnemonic: BIP39.mnemonic(entropy: Data(repeating: 0x5A, count: 16))))
        let foreignAccount = try BIP86.accountKey(from: foreign, coinType: 1, account: 0)
        #expect(foreignAccount.isPrivate)
        #expect(foreignAccount.depth == 3)
        #expect(foreignAccount.childIndex == accountKey.childIndex)
        #expect(foreignAccount.neutered != (await wallet.accountKey), "a different chain entirely")

        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: foreignAccount.serialized(network: .testnet),
                                    masterFingerprint: master.fingerprint), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }
        // And refused where it would have been spent, not only where it is read.
        try await fund(wallet, amount: 500_000, height: 100)
        try await matureCoinbase(wallet, height: 100)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.buildSend(
                payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
                feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        }
    }

    /// The path every launch after the first takes. `Wallet.open` rebuilds
    /// `accountKey` from the descriptor's xpub rather than from a constructor
    /// argument, so it is a different way into `accountPrivateKey` — and since
    /// the binding check above compares the stored key against exactly that
    /// rebuilt value, a wallet that reopens differently would not merely drift,
    /// it would refuse to sign at all.
    @Test("an account-custody wallet reopens and derives the same signing keys",
          arguments: [BitcoinNetwork.signet, .mainnet], [UInt32(0), 5])
    func reopenedAccountWalletSignsTheSame(network: BitcoinNetwork, account: UInt32) async throws {
        let store = InMemoryKeyStore()
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master,
                                              coinType: Wallet.coinType(for: network),
                                              account: account)
        let storageURL = tempFileURL("account-custody-reopen.json")
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }

        let created = try Wallet.create(accountKey: accountKey,
                                        masterFingerprint: master.fingerprint,
                                        network: network, keyStore: store,
                                        storageURL: storageURL, creationHeight: 100,
                                        account: account)
        let reopened = try Wallet.open(storageURL: storageURL, keyStore: store)

        #expect(await created.id == reopened.id)
        #expect(await created.accountKey == reopened.accountKey)
        #expect(await created.descriptor.serialized() == reopened.descriptor.serialized())
        for (chain, index) in Self.coordinates {
            #expect(try await reopened.keyPathSecret(chain: chain, index: index)
                == (try await created.keyPathSecret(chain: chain, index: index)),
                "key at \(chain)/\(index) after reopening")
            #expect(try await reopened.address(chain: chain, index: index)
                == (try await created.address(chain: chain, index: index)))
        }
    }

    /// A wallet at an account other than zero, spending. The differential
    /// witness compares keys; this is the whole send under account custody at
    /// account 5, so nothing that only shows up when a transaction is built —
    /// the PSBT origin path, and the binding check every input signature goes
    /// through — is left to account 0 alone.
    @Test("an account-5 wallet under account custody builds and signs a send")
    func sendAtAccountFive() async throws {
        let (_, account, _, _) = try Self.bothCustodies(entropy: testEntropy, account: 5)
        try await fund(account, amount: 500_000, height: 100)
        try await matureCoinbase(account, height: 100)
        let prepared = try await account.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })

        // The origin a hardware signer would read names account 5, hardened,
        // and the signature verifies against the coin it spends.
        let origin = try #require(prepared.built.psbt.inputs[0].tapBIP32Derivation.values.first)
        #expect(origin.path == [86, 1, 5].map { $0 + HDKey.hardenedOffset } + [0, 0])
        #expect(origin.masterFingerprint == UInt32(await account.id, radix: 16))
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

    /// The neighbouring-account refusals, at an account that is not zero. Both
    /// directions matter and they are caught in different places: a key for
    /// account 6 stored in an account-5 wallet is a signing-time refusal, and
    /// an account-0 key handed to a constructor told to build account 5 never
    /// gets as far as a wallet.
    @Test("an account-5 wallet refuses a neighbouring account's key at either end")
    func accountFiveRefusesItsNeighbours() async throws {
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let store = InMemoryKeyStore()
        let five = try BIP86.accountKey(from: master, coinType: 1, account: 5)
        let wallet = try Wallet.create(accountKey: five, masterFingerprint: master.fingerprint,
                                       network: .signet, keyStore: store, creationHeight: 100,
                                       account: 5)
        let id = await wallet.id

        // Account 6 under the same master: right fingerprint, right depth,
        // wrong child index, and every signature it makes would be valid.
        let six = try BIP86.accountKey(from: master, coinType: 1, account: 6)
        try store.delete(walletID: id)
        try store.store(.accountKey(xprv: six.serialized(network: .testnet),
                                    masterFingerprint: master.fingerprint), for: id)
        await #expect(throws: WalletError.accountKeyMismatch) {
            _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
        }

        // And the mirror image at creation: an account-0 key with `account: 5`
        // asked for. The origin path the constructor builds ends in 5', the key
        // says 0', and the childIndex guard is what notices.
        let zero = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        #expect(throws: WalletError.accountKeyMismatch) {
            _ = try Wallet.create(accountKey: zero, masterFingerprint: master.fingerprint,
                                  network: .signet, keyStore: InMemoryKeyStore(), account: 5)
        }
    }

    /// An account index with the hardened bit already set. The path both
    /// constructors build adds that bit, so the addition has nowhere to go: the
    /// root constructor reaches it through a path string and reports
    /// `invalidPath`, and this one used to compute the same sum directly and
    /// take the process down with an overflow trap before any guard read the
    /// argument. A caller that gets an account index wrong deserves an error,
    /// and a library that aborts the host process cannot be caught by anything.
    @Test("an account index past the hardened boundary is refused by both constructors")
    func hardenedAccountIndexRefused() throws {
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        for account in [UInt32(0x8000_0000), 0x8000_0005, .max] {
            #expect(throws: BIP32Error.invalidPath) {
                _ = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                      account: account)
            }
            #expect(throws: BIP32Error.invalidPath) {
                _ = try Wallet.create(accountKey: accountKey,
                                      masterFingerprint: master.fingerprint,
                                      network: .signet, keyStore: InMemoryKeyStore(),
                                      account: account)
            }
        }
        // One below the boundary is a real account, so the mismatched key
        // reaches the binding guard rather than the refusal above: the two
        // failures are told apart by which error comes back.
        #expect(throws: WalletError.accountKeyMismatch) {
            _ = try Wallet.create(accountKey: accountKey, masterFingerprint: master.fingerprint,
                                  network: .signet, keyStore: InMemoryKeyStore(),
                                  account: 0x7FFF_FFFF)
        }
    }

    /// The same substitution as `foreignSeedAccountKeyRefused`, against the two
    /// custody shapes that hold a root secret. A KeyStore entry is filed under
    /// the wallet ID and the ID is a fingerprint, so a seed or master xprv that
    /// is not this wallet's can sit where this wallet's belongs. It is walked
    /// down the origin path like any other root secret and produces a real
    /// 32-byte signing secret for a chain this wallet does not own.
    ///
    /// The binding check used to be on the account-key branch alone. On these
    /// two the send got as far as `psbt.finalize()`, which reported
    /// `input 0 invalid tap key signature` — the wrong error, two layers down,
    /// and only because finalize self-verifies at all.
    @Test("a root secret that is not this wallet's is refused, not signed with",
          arguments: [BitcoinNetwork.signet, .mainnet])
    func foreignRootSecretRefused(network: BitcoinNetwork) async throws {
        let store = InMemoryKeyStore()
        let wallet = try Wallet.create(network: network, keyStore: store,
                                       entropy: testEntropy, creationHeight: 100)
        let id = await wallet.id
        let foreignMnemonic = try BIP39.mnemonic(entropy: Data(repeating: 0x5A, count: 16))
        let foreignMaster = try HDKey(seed: BIP39.seed(mnemonic: foreignMnemonic))
        try await fund(wallet, amount: 500_000, height: 100)
        try await matureCoinbase(wallet, height: 100)

        for foreign in [WalletSecret.mnemonic(foreignMnemonic),
                        .masterKey(foreignMaster.serialized(
                            network: Wallet.hdNetwork(for: network)))] {
            try store.delete(walletID: id)
            try store.store(foreign, for: id)
            await #expect(throws: WalletError.accountKeyMismatch) {
                _ = try await wallet.keyPathSecret(chain: .receive, index: 0)
            }
            await #expect(throws: WalletError.accountKeyMismatch) {
                _ = try await wallet.buildSend(
                    payments: [Payment(amount: 100_000, scriptPubKey: TestScripts.p2trDestination)],
                    feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
            }
        }
    }

    /// The control the refusals above need: an honest wallet still binds. Both
    /// networks, both root shapes, and both ways into `accountPrivateKey` — the
    /// constructor's account key and the one `Wallet.open` rebuilds from the
    /// descriptor's xpub — because a binding check that refuses the wallet it
    /// was written to protect is worse than no check at all.
    @Test("an honest root secret still signs, at creation and after reopening",
          arguments: [BitcoinNetwork.signet, .mainnet])
    func honestRootSecretStillBinds(network: BitcoinNetwork) async throws {
        let store = InMemoryKeyStore()
        let storageURL = tempFileURL("root-custody-reopen.json")
        defer { try? FileManager.default.removeItem(at: storageURL.deletingLastPathComponent()) }
        let created = try Wallet.create(network: network, keyStore: store, storageURL: storageURL,
                                        entropy: testEntropy, creationHeight: 100)
        let id = await created.id

        // The mnemonic the constructor stored, then the same seed's master
        // xprv in its place: the other root shape, walked the same way.
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let secrets: [WalletSecret] = [
            .mnemonic(testMnemonic),
            .masterKey(master.serialized(network: Wallet.hdNetwork(for: network))),
        ]
        for secret in secrets {
            try store.delete(walletID: id)
            try store.store(secret, for: id)
            let reopened = try Wallet.open(storageURL: storageURL, keyStore: store)
            for (chain, index) in Self.coordinates {
                let fromCreated = try await created.keyPathSecret(chain: chain, index: index)
                #expect(fromCreated.count == 32)
                #expect(try await reopened.keyPathSecret(chain: chain, index: index) == fromCreated,
                        "key at \(chain)/\(index) after reopening")
            }
        }
    }

    /// Creation is one logical operation under either custody. The mnemonic
    /// constructor's rollback has always been covered (`WalletTests`'s
    /// `createPersistenceRollback`); this is the same contract through the
    /// constructor that stores an account key, so that half of it has a
    /// witness too rather than resting on the two sharing a helper today.
    @Test("failed persistence rolls back the stored account key")
    func accountCreatePersistenceRollback() throws {
        let keyStore = InMemoryKeyStore()
        let master = try HDKey(seed: BIP39.seed(mnemonic: testMnemonic))
        let accountKey = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "account-create-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory where the state file goes: the write throws, after the
        // account key is already in the store.
        let unwritable = root.appending(path: "wallet.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unwritable, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            _ = try Wallet.create(accountKey: accountKey, masterFingerprint: master.fingerprint,
                                  network: .signet, keyStore: keyStore, storageURL: unwritable)
        }
        #expect(throws: KeyStoreError.notFound(walletID: "73c5da0a")) {
            _ = try keyStore.load(walletID: "73c5da0a")
        }
    }
}
