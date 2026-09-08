import WalletCore
import Foundation
import P256K
import Testing
import TestSupport

/// Mixed-implementation vault interoperability (invariant S8, issue #58).
///
/// Two Winnow installations are not implementation diversity: they share every
/// line of the code being tested. This suite gives one of a 2-of-3 vault's
/// three keys to **Bitcoin Core's descriptor wallet** — a wallet written by
/// other people, from the spec — and requires it to co-sign a script-path
/// spend that then confirms on chain.
///
/// What Core is asked to do, in order: parse `tr(NUMS, sortedmulti_a(...))`
/// with BIP389 multipath key expressions, agree with us about the addresses it
/// derives, hold one private key of three, produce a BIP342 script-path
/// partial signature into a PSBT we built, and let our finalizer combine its
/// signature with ours into a transaction the network accepts.
///
/// Anything Core cannot do is recorded as unsupported rather than skipped —
/// an interop matrix that only lists successes is a marketing document.
@Suite("vault interop with Bitcoin Core", .enabled(if: diffEnabled))
struct VaultInteropDiffTests {
    private let endpoint = PeerEndpoint(host: BitcoinCLI.nodeHost, port: BitcoinCLI.p2pPort)

    enum VaultInteropError: Error, CustomStringConvertible {
        case setup(String)
        var description: String {
            switch self { case let .setup(message): "interop setup: \(message)" }
        }
    }

    @Test("Core co-signs a 2-of-3 script-path spend and it confirms")
    func coreCosignsScriptPathSpend() async throws {
        func trace(_ step: String) { FileHandle.standardError.write(Data("interop: \(step)\n".utf8)) }
        let params = NetworkParams.customSignet(challenge: BitcoinCLI.challenge,
                                                defaultPort: BitcoinCLI.p2pPort)

        // 1. One cosigner is Core's; two are ours.
        let core = try CoreSigner(wallet: "interop")
        var ourMasters: [HDKey] = []
        for index: UInt8 in 0 ..< 2 {
            let entropy = Data([0x40 + index] + Data(repeating: 0, count: 15))
            ourMasters.append(try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: entropy))))
        }
        let coreExpression = core.publicExpression + "/<0;1>/*"
        let cosigners = [coreExpression] + (try ourMasters.map { try TestVaults.keyExpression(master: $0) })
        let descriptor = try Vault.multiADescriptor(threshold: 2, cosigners: cosigners)
        let vault = try Vault(descriptor: descriptor, network: .signet)
        #expect(vault.usesUnspendableInternalKey, "a vault Core co-signs must be script-path only")

        // 2. Agreement before money: Core must derive the same addresses from
        //    the same descriptor. If this fails nothing later is meaningful.
        let ourAddresses = try (0 ..< 3).map { try vault.address(index: UInt32($0)) }
        // `serialized()` carries our own checksum, so handing it straight to
        // Core also checks that our checksum implementation agrees with theirs
        // — a wrong one is rejected outright rather than silently tolerated.
        let ourText = descriptor.serialized()
        let derived = try BitcoinCLI.runJSON(["deriveaddresses", ourText, "[0,2]"])
        // Multipath descriptors derive one array per chain; receive is first.
        let coreAddresses = ((derived as? [Any])?.first as? [Any])?.compactMap { $0 as? String }
        #expect(coreAddresses == ourAddresses,
                "Core and Winnow disagree about the vault's addresses")
        trace("descriptor agreement over \(ourAddresses.count) addresses")

        // 3. Core imports the same vault, holding exactly one of the three keys.
        let signerWallet = "interop-signer-\(UInt32.random(in: 0 ..< 1_000_000))"
        _ = try BitcoinCLI.run(["-named", "createwallet", "wallet_name=\(signerWallet)", "blank=true"])
        let body = String(ourText.split(separator: "#")[0])
        let privateText = body.replacingOccurrences(
            of: coreExpression, with: core.privateExpression + "/<0;1>/*")
        try #require(privateText != body, "Core's leg was not substituted")
        let privateChecksum = try BitcoinCLI.string(
            BitcoinCLI.runObject(["getdescriptorinfo", privateText]), "checksum")
        let imported = try BitcoinCLI.runJSON(
            ["importdescriptors",
             #"[{"desc":"\#(privateText)#\#(privateChecksum)","timestamp":"now","active":true,"range":[0,5]}]"#],
            wallet: signerWallet)
        let importOK = ((imported as? [Any])?.first as? [String: Any])?["success"] as? Bool
        #expect(importOK == true, "Core refused the vault descriptor")
        trace("Core imported the vault holding 1 of 3 keys")
        let addrInfo = try BitcoinCLI.runObject(["getaddressinfo", ourAddresses[0]], wallet: signerWallet)
        trace("Core wallet view of vault addr0: ismine=\(String(describing: addrInfo["ismine"]))"
            + " solvable=\(String(describing: addrInfo["solvable"]))")

        // 4. Fund address 0 and mature it.
        let vaultScript = try vault.scriptPubKey(index: 0)
        let burnScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/2")))
        let fundingHash = try await SignetMiner.mineOntoTip(payingTo: vaultScript)
        for _ in 0 ..< 99 { _ = try await SignetMiner.mineOntoTip(payingTo: burnScript) }
        let fundingBlock = try BitcoinCLI.runObject(["getblock", fundingHash, "2"])
        let fundingHeight = try UInt32(BitcoinCLI.int(fundingBlock, "height"))
        #expect(try BitcoinCLI.int(fundingBlock, "confirmations") >= 100, "funding matured")
        let coinbase = try #require(
            (try BitcoinCLI.array(fundingBlock, "tx")).first as? [String: Any])
        let fundingTxid = try BitcoinCLI.string(coinbase, "txid")
        let utxo = WalletUTXO(txid: Data(Data(hex: fundingTxid)!.reversed()), vout: 0,
                              amount: 5_000_000_000, scriptPubKey: vaultScript,
                              chain: .receive, index: 0, height: fundingHeight,
                              isCoinbase: true)
        trace("vault funded at height \(fundingHeight)")

        // 5. We build the spend and sign one leg.
        let payoutScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/3")))
        let tip = try UInt32(BitcoinCLI.blockCount())
        var psbt = try vault.createSpend(
            utxos: [utxo], payments: [Payment(amount: 1_000_000, scriptPubKey: payoutScript)],
            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: tip)
        let unsignedBase64 = psbt.base64
        try vault.partialSign(&psbt, master: ourMasters[0], knownUTXOs: [utxo],
                              ownedOutputCoordinates: [.init(choice: 1, index: 0)],
                              chainTip: tip)
        let ourSignatures = psbt.inputs[0].tapScriptSignatures.count
        #expect(ourSignatures == 1, "our own leg signed")
        trace("Winnow signed 1 leg")

        // 6. Core signs the PSBT we produced. This is the claim under test:
        //    an independent implementation reading our PSBT, finding its own
        //    key in it, and producing a BIP342 script-path signature.
        //    Use the same v0 export and normalized import as the app.
        let handedToCore = try psbt.base64V0()
        // finalize=false is load-bearing. Left at its default, Core signs AND
        // finalizes, folding both partial signatures into a final witness and
        // reporting complete=1 — at which point the tap script sigs are gone
        // and it looks like Core signed nothing. We want its *partial*
        // signature so that our finalizer is the one combining the two.
        let processed = try BitcoinCLI.runObject(
            ["walletprocesspsbt", handedToCore, "true", "DEFAULT", "true", "false"],
            wallet: signerWallet)
        let coreText = try BitcoinCLI.string(processed, "psbt")
        psbt = try psbt.combined(with: [PSBT(base64: coreText)])
        let bothSignatures = psbt.inputs[0].tapScriptSignatures.count
        #expect(bothSignatures == 2,
                "expected our signature plus Core's, got \(bothSignatures)")
        trace("Core signed: \(bothSignatures) script-path signatures present")

        // 7. Our finalizer combines them, and the network is the judge.
        var finalPSBT = psbt
        let transaction = try vault.finalizeSpend(&finalPSBT, knownUTXOs: [utxo],
                                                  ownedOutputCoordinates: [.init(choice: 1, index: 0)],
                                                  chainTip: tip)
        let raw = transaction.serialized(includeWitness: true).hex
        let accept = try BitcoinCLI.runJSON(["testmempoolaccept", "[\"\(raw)\"]"])
        let verdict = (accept as? [Any])?.first as? [String: Any]
        #expect(verdict?["allowed"] as? Bool == true,
                "Core rejected the co-signed transaction: \(verdict?["reject-reason"] ?? "unknown")")
        let txid = try BitcoinCLI.run(["sendrawtransaction", raw])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await SignetMiner.mineOntoTip(payingTo: burnScript)
        let confirmed = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        #expect(try BitcoinCLI.int(confirmed, "confirmations") >= 1,
                "the co-signed spend did not confirm")
        trace("confirmed \(txid.prefix(16))… — unsigned was \(unsignedBase64.prefix(12))…")
    }
    /// The inverse composition: both signatures that satisfy the 2-of-3
    /// threshold come from independent Core wallets, and our key never
    /// signs. Our implementation is creator, envelope converter, combiner,
    /// finalizer, and broadcaster only — which is exactly the claim a
    /// cosigner-app deployment makes, and it must hold with zero of our own
    /// signatures in the witness. The PSBT also travels Core-to-Core in
    /// between: A's signed envelope feeds B, so the ceremony includes a leg
    /// no Winnow code touches at all.
    @Test("two Core wallets satisfy the threshold; our key never signs")
    func twoCoreSignersSatisfyThreshold() async throws {
        func trace(_ step: String) { FileHandle.standardError.write(Data("interop2: \(step)\n".utf8)) }

        // 1. Two cosigners are Core's, from two wallets Core generated; one
        //    is ours and stays silent.
        let coreA = try CoreSigner(wallet: "interop-a")
        let coreB = try CoreSigner(wallet: "interop-b")
        let silentEntropy = Data([0x60] + Data(repeating: 0, count: 15))
        let silentMaster = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: silentEntropy)))
        let silentAccount = try silentMaster.derived(path: "m/86'/1'/0'")
        let silentExpression = try TestVaults.keyExpression(master: silentMaster)
        let expressionA = coreA.publicExpression + "/<0;1>/*"
        let expressionB = coreB.publicExpression + "/<0;1>/*"
        let descriptor = try Vault.multiADescriptor(
            threshold: 2, cosigners: [expressionA, expressionB, silentExpression])
        let vault = try Vault(descriptor: descriptor, network: .signet)
        #expect(vault.usesUnspendableInternalKey)

        // 2. Address agreement, as always, before any money moves.
        let ourText = descriptor.serialized()
        let ourAddresses = try (0 ..< 3).map { try vault.address(index: UInt32($0)) }
        let derived = try BitcoinCLI.runJSON(["deriveaddresses", ourText, "[0,2]"])
        let coreAddresses = ((derived as? [Any])?.first as? [Any])?.compactMap { $0 as? String }
        #expect(coreAddresses == ourAddresses)
        trace("descriptor agreement over \(ourAddresses.count) addresses")

        // 3. Two signer wallets, each importing the vault with exactly its
        //    own private leg substituted in.
        func signerWallet(substituting expression: String,
                          privateExpression: String, tag: String) throws -> String {
            let wallet = "interop2-\(tag)-\(UInt32.random(in: 0 ..< 1_000_000))"
            _ = try BitcoinCLI.run(["-named", "createwallet", "wallet_name=\(wallet)", "blank=true"])
            let body = String(ourText.split(separator: "#")[0])
            let privateText = body.replacingOccurrences(
                of: expression, with: privateExpression + "/<0;1>/*")
            try #require(privateText != body, "\(tag)'s leg was not substituted")
            let checksum = try BitcoinCLI.string(
                BitcoinCLI.runObject(["getdescriptorinfo", privateText]), "checksum")
            let imported = try BitcoinCLI.runJSON(
                ["importdescriptors",
                 #"[{"desc":"\#(privateText)#\#(checksum)","timestamp":"now","active":true,"range":[0,5]}]"#],
                wallet: wallet)
            let ok = ((imported as? [Any])?.first as? [String: Any])?["success"] as? Bool
            #expect(ok == true, "Core refused the vault descriptor for \(tag)")
            return wallet
        }
        let walletA = try signerWallet(substituting: expressionA,
                                       privateExpression: coreA.privateExpression, tag: "a")
        let walletB = try signerWallet(substituting: expressionB,
                                       privateExpression: coreB.privateExpression, tag: "b")
        trace("two Core signer wallets imported, one key each")

        // 4. Fund and mature.
        let vaultScript = try vault.scriptPubKey(index: 0)
        let burnScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/5")))
        let fundingHash = try await SignetMiner.mineOntoTip(payingTo: vaultScript)
        for _ in 0 ..< 99 { _ = try await SignetMiner.mineOntoTip(payingTo: burnScript) }
        let fundingBlock = try BitcoinCLI.runObject(["getblock", fundingHash, "2"])
        let fundingHeight = try UInt32(BitcoinCLI.int(fundingBlock, "height"))
        let coinbase = try #require(
            (try BitcoinCLI.array(fundingBlock, "tx")).first as? [String: Any])
        let fundingTxid = try BitcoinCLI.string(coinbase, "txid")
        let utxo = WalletUTXO(txid: Data(Data(hex: fundingTxid)!.reversed()), vout: 0,
                              amount: 5_000_000_000, scriptPubKey: vaultScript,
                              chain: .receive, index: 0, height: fundingHeight,
                              isCoinbase: true)
        trace("vault funded at height \(fundingHeight)")

        // 5. We create the spend and sign nothing.
        let payoutScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/6")))
        let tip = try UInt32(BitcoinCLI.blockCount())
        var psbt = try vault.createSpend(
            utxos: [utxo], payments: [Payment(amount: 1_000_000, scriptPubKey: payoutScript)],
            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: tip)
        #expect(psbt.inputs[0].tapScriptSignatures.isEmpty, "creator must not have signed")

        // 6. A signs our envelope; B signs A's output — a Core-to-Core leg
        //    with no Winnow code in it. Both with finalize=false, for the
        //    same load-bearing reason as the first test.
        let toA = try psbt.base64V0()
        let fromA = try BitcoinCLI.string(
            BitcoinCLI.runObject(["walletprocesspsbt", toA, "true", "DEFAULT", "true", "false"],
                                 wallet: walletA), "psbt")
        let fromB = try BitcoinCLI.string(
            BitcoinCLI.runObject(["walletprocesspsbt", fromA, "true", "DEFAULT", "true", "false"],
                                 wallet: walletB), "psbt")
        psbt = try psbt.combined(with: [PSBT(base64: fromB)])
        let signatures = psbt.inputs[0].tapScriptSignatures
        #expect(signatures.count == 2, "expected both Core signatures, got \(signatures.count)")
        let ourLeafKey = try BIP86.xonlyPublicKey(
            of: silentAccount.derived(path: "0/0"))
        #expect(!signatures.keys.contains { $0.publicKey == Data(ourLeafKey) },
                "our silent key must not appear among the signatures")
        trace("both signatures are Core's; ours is absent")

        // 7. Our finalizer assembles a transaction the network accepts.
        var finalPSBT = psbt
        let transaction = try vault.finalizeSpend(
            &finalPSBT, knownUTXOs: [utxo],
            ownedOutputCoordinates: [.init(choice: 1, index: 0)], chainTip: tip)
        let raw = transaction.serialized(includeWitness: true).hex
        let accept = try BitcoinCLI.runJSON(["testmempoolaccept", "[\"\(raw)\"]"])
        let verdict = (accept as? [Any])?.first as? [String: Any]
        #expect(verdict?["allowed"] as? Bool == true,
                "network rejected the two-Core spend: \(verdict?["reject-reason"] ?? "unknown")")
        let txid = try BitcoinCLI.run(["sendrawtransaction", raw])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await SignetMiner.mineOntoTip(payingTo: burnScript)
        let confirmed = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        #expect(try BitcoinCLI.int(confirmed, "confirmations") >= 1)
        trace("confirmed \(txid.prefix(16))… with zero Winnow signatures")
    }

    /// Two-level custody by composition: a MuSig2 2-of-2 *group* is one
    /// signer of the 2-of-3. From the leaf's point of view the group is just
    /// an x-only key; the multi-level part is that no single person can
    /// produce that key's signature. The threshold is then met by the group
    /// plus Core — two different kinds of "signer", neither of them us.
    ///
    /// The group's leg is a plain BIP342 script-path signature produced by
    /// the BIP327 two-round ceremony over the script-path sighash, with no
    /// taproot tweak — the aggregate is a leaf key, not an output key. The
    /// finalizer BIP340-verifies every signature before counting it, so a
    /// wrong aggregate, parity, or sighash fails loudly here rather than at
    /// the mempool.
    @Test("a MuSig2 group is one signer of a 2-of-3, beside Core")
    func muSig2GroupAsOneSignerOfScriptPathVault() async throws {
        func trace(_ step: String) { FileHandle.standardError.write(Data("interop3: \(step)\n".utf8)) }

        // 1. The group: two members with their own secrets; their aggregate
        //    x-only key is the vault's first cosigner. Core is the second;
        //    ours is the third and never signs.
        let memberSecrets = [Data([0x71] + Data(repeating: 0x11, count: 31)),
                             Data([0x72] + Data(repeating: 0x22, count: 31))]
        let memberKeys = try memberSecrets.map {
            try P256K.Signing.PrivateKey(dataRepresentation: $0).publicKey.dataRepresentation
        }
        // BIP328: the aggregate becomes a synthetic xpub, so the group is a
        // derivable cosigner exactly like any other — fresh leaf key per
        // address index, no special-casing in the descriptor.
        let aggregateCompressed = try MuSig.aggregate(memberKeys)
        let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregateCompressed)
        let groupExpression = "[\(String(format: "%08x", synthetic.fingerprint))]"
            + "\(synthetic.serialized(network: .testnet))/<0;1>/*"
        let core = try CoreSigner(wallet: "interop-a")
        let coreExpression = core.publicExpression + "/<0;1>/*"
        let silentEntropy = Data([0x73] + Data(repeating: 0, count: 15))
        let silentMaster = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: silentEntropy)))
        let silentExpression = try TestVaults.keyExpression(master: silentMaster)
        let descriptor = try Vault.multiADescriptor(
            threshold: 2, cosigners: [groupExpression, coreExpression, silentExpression])
        let vault = try Vault(descriptor: descriptor, network: .signet)
        #expect(vault.usesUnspendableInternalKey)
        trace("group synthetic xpub \(synthetic.fingerprint) is cosigner 1 of 3")

        // 2. Core must agree about the addresses even with a raw-key
        //    participant in the leaf.
        let ourText = descriptor.serialized()
        let ourAddresses = try (0 ..< 2).map { try vault.address(index: UInt32($0)) }
        let derived = try BitcoinCLI.runJSON(["deriveaddresses", ourText, "[0,1]"])
        let coreAddresses = ((derived as? [Any])?.first as? [Any])?.compactMap { $0 as? String }
        #expect(coreAddresses == ourAddresses,
                "Core disagrees about a vault with a synthetic-xpub participant")
        trace("descriptor agreement with a synthetic-xpub cosigner")

        // 3. Core imports its private leg as a signer wallet.
        let signerWallet = "interop3-\(UInt32.random(in: 0 ..< 1_000_000))"
        _ = try BitcoinCLI.run(["-named", "createwallet", "wallet_name=\(signerWallet)", "blank=true"])
        let body = String(ourText.split(separator: "#")[0])
        let privateText = body.replacingOccurrences(
            of: coreExpression, with: core.privateExpression + "/<0;1>/*")
        try #require(privateText != body)
        let checksum = try BitcoinCLI.string(
            BitcoinCLI.runObject(["getdescriptorinfo", privateText]), "checksum")
        let imported = try BitcoinCLI.runJSON(
            ["importdescriptors",
             #"[{"desc":"\#(privateText)#\#(checksum)","timestamp":"now","active":true,"range":[0,5]}]"#],
            wallet: signerWallet)
        #expect(((imported as? [Any])?.first as? [String: Any])?["success"] as? Bool == true)

        // 4. Fund and mature.
        let vaultScript = try vault.scriptPubKey(index: 0)
        let burnScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/7")))
        let fundingHash = try await SignetMiner.mineOntoTip(payingTo: vaultScript)
        for _ in 0 ..< 99 { _ = try await SignetMiner.mineOntoTip(payingTo: burnScript) }
        let fundingBlock = try BitcoinCLI.runObject(["getblock", fundingHash, "2"])
        let fundingHeight = try UInt32(BitcoinCLI.int(fundingBlock, "height"))
        let coinbase = try #require(
            (try BitcoinCLI.array(fundingBlock, "tx")).first as? [String: Any])
        let fundingTxid = try BitcoinCLI.string(coinbase, "txid")
        let utxo = WalletUTXO(txid: Data(Data(hex: fundingTxid)!.reversed()), vout: 0,
                              amount: 5_000_000_000, scriptPubKey: vaultScript,
                              chain: .receive, index: 0, height: fundingHeight,
                              isCoinbase: true)
        trace("vault funded at height \(fundingHeight)")

        // 5. We create the spend and sign nothing.
        let payoutScript = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/8")))
        let tip = try UInt32(BitcoinCLI.blockCount())
        var psbt = try vault.createSpend(
            utxos: [utxo], payments: [Payment(amount: 1_000_000, scriptPubKey: payoutScript)],
            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: tip)
        #expect(psbt.inputs[0].tapScriptSignatures.isEmpty)

        // 6. The group's leg: BIP327 two rounds over the script-path sighash,
        //    no tweaks — the aggregate is a leaf key, not an output key.
        let leaf = try #require(psbt.inputs[0].tapLeafScripts.first)
        let tx = try psbt.unsignedTransaction()
        let sighash = try SighashBIP341.sighash(
            tx: tx, inputIndex: 0, spentOutputs: [utxo.spentOutput], hashType: .default,
            scriptPath: .init(leafScript: Script(leaf.script), leafVersion: leaf.leafVersion))
        // The leaf key is the BIP328 child at 0/0, so the session carries
        // the two non-hardened derivation tweaks — the same shape the
        // key-path vaults use, applied to a script-path message.
        let tweak0 = MuSig.bip328Tweak(chainCode: synthetic.chainCode,
                                       aggregatePublicKey: aggregateCompressed, index: 0)
        let child0 = try synthetic.derived(path: "0")
        let tweak00 = MuSig.bip328Tweak(chainCode: child0.chainCode,
                                        aggregatePublicKey: child0.publicKey, index: 0)
        let groupLeafKey = try synthetic.derived(path: "0/0").publicKey.dropFirst()
        let baseAggregateXonly = Data(aggregateCompressed.dropFirst())
        var nonces: [(secret: Data, public_: Data)] = []
        for (secret, publicKey) in zip(memberSecrets, memberKeys) {
            let nonce = try MuSig.nonceGenerate(secretKey: secret, publicKey: publicKey,
                                                 aggregateKey: baseAggregateXonly, message: sighash)
            nonces.append((nonce.secretNonce, nonce.publicNonce))
        }
        let aggregateNonce = try MuSig.nonceAggregate(publicNonces: nonces.map(\.public_))
        let session = MuSig.Session(aggregateNonce: aggregateNonce, publicKeys: memberKeys,
                                     tweaks: [tweak0, tweak00],
                                     isXOnlyTweaks: [false, false], message: sighash)
        var partials: [Data] = []
        for (index, member) in memberSecrets.enumerated() {
            var secretNonce = nonces[index].secret
            let partial = try MuSig.partialSign(secretNonce: &secretNonce, secretKey: member,
                                                 session: session)
            #expect(try MuSig.partialVerify(partialSignature: partial,
                                            publicNonce: nonces[index].public_,
                                            publicKey: memberKeys[index], session: session),
                    "member \(index)'s partial signature failed verification")
            partials.append(partial)
        }
        let groupSignature = try MuSig.partialSigAggregate(partialSignatures: partials,
                                                            session: session)
        psbt.inputs[0].pairs.append(PSBT.KeyValue(
            type: 0x14, keyData: Data(groupLeafKey) + leaf.leafHash, value: groupSignature))
        trace("group produced one BIP342 signature from two partials")

        // 7. Core signs its leg from our envelope.
        let processed = try BitcoinCLI.runObject(
            ["walletprocesspsbt", try psbt.base64V0(), "true", "DEFAULT", "true", "false"],
            wallet: signerWallet)
        psbt = try psbt.combined(with: [PSBT(base64: BitcoinCLI.string(processed, "psbt"))])
        #expect(psbt.inputs[0].tapScriptSignatures.count == 2,
                "expected the group's signature plus Core's")

        // 8. Our finalizer verifies both — a bad aggregate dies here — and
        //    the network judges the rest.
        var finalPSBT = psbt
        let transaction = try vault.finalizeSpend(
            &finalPSBT, knownUTXOs: [utxo],
            ownedOutputCoordinates: [.init(choice: 1, index: 0)], chainTip: tip)
        let raw = transaction.serialized(includeWitness: true).hex
        let accept = try BitcoinCLI.runJSON(["testmempoolaccept", "[\"\(raw)\"]"])
        let verdict = (accept as? [Any])?.first as? [String: Any]
        #expect(verdict?["allowed"] as? Bool == true,
                "network rejected the group-signed spend: \(verdict?["reject-reason"] ?? "unknown")")
        let txid = try BitcoinCLI.run(["sendrawtransaction", raw])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await SignetMiner.mineOntoTip(payingTo: burnScript)
        let confirmed = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        #expect(try BitcoinCLI.int(confirmed, "confirmations") >= 1)
        trace("confirmed \(txid.prefix(16))… — one signer was a 2-of-2 group")
    }

    @Test("Core and Winnow complete a MuSig2 payment", arguments: [false, true])
    func coreMuSig2Payment(coreFirst: Bool) async throws {
        func trace(_ step: String) { FileHandle.standardError.write(Data("musig: \(step)\n".utf8)) }
        let core = try CoreSigner(wallet: "musig-\(UUID().uuidString)")
        let ourMaster = try HDKey(seed: BIP39.seed(
            mnemonic: BIP39.mnemonic(entropy: Data([0x60] + Data(repeating: 0, count: 15)))))
        // BIP390: participants carry no derivation of their own when the
        // musig() itself has the suffix.
        let ourBare = try TestVaults.bareKeyExpression(master: ourMaster)
        let vault = try Vault("tr(musig(\(core.publicExpression),\(ourBare))/<0;1>/*)",
                              network: .signet)

        // Agreement first, as with the script-path vault.
        let ourText = vault.descriptor.serialized()
        let derived = try BitcoinCLI.runJSON(["deriveaddresses", ourText, "[0,1]"])
        let coreAddresses = ((derived as? [Any])?.first as? [Any])?.compactMap { $0 as? String }
        let ourAddresses = try (0 ..< 2).map { try vault.address(index: UInt32($0)) }
        #expect(coreAddresses == ourAddresses, "Core and Winnow disagree about musig addresses")
        trace("descriptor agreement over \(ourAddresses.count) musig addresses")

        try core.importVault(vault)
        let script = try vault.scriptPubKey(index: 0)
        let payout = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: testMaster().derived(path: "m/86'/1'/9'/0/4")))
        let block = try await SignetMiner.mineOntoTip(payingTo: script)
        let height = try BitcoinCLI.blockHeight(of: block)
        try await SignetMiner.ensureChainHeight(atLeast: height + Int(Wallet.coinbaseMaturity) - 1)
        let fundingTxid = try BitcoinCLI.coinbaseTxid(blockHash: block)
        let coin = try #require(BitcoinCLI.unspents(scriptHex: script.hex).first { $0.txid == fundingTxid })
        let utxo = WalletUTXO(txid: Data(Data(hex: coin.txid)!.reversed()), vout: coin.vout,
                              amount: coin.amount, scriptPubKey: script, chain: .receive,
                              index: 0, height: coin.height, isCoinbase: true)
        let tip = UInt32(try BitcoinCLI.blockCount())
        let coordinates = [Vault.OutputCoordinate(choice: 1, index: 0)]
        var psbt = try vault.createSpend(
            utxos: [utxo], payments: [Payment(amount: 50_000, scriptPubKey: payout)],
            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: tip)
        let unsigned = try psbt.unsignedTransaction()
        func process(_ proposal: PSBT) throws -> PSBT {
            let returned = try core.process(proposal)
            #expect(try returned.unsignedTransaction() == unsigned, "Core changed the payment")
            return returned
        }
        if coreFirst {
            psbt = try process(psbt)
            #expect(psbt.inputs[0].musig2PubNonces.count == 1)
            #expect(psbt.inputs[0].musig2PartialSigs.isEmpty)
        }
        let context = try vault.muSig2Context(choice: 0, index: 0)
        var secretNonces = try vault.muSig2AttachNonce(
            &psbt, input: 0, context: context, master: ourMaster, knownUTXOs: [utxo],
            ownedOutputCoordinates: coordinates, chainTip: tip)
        if !coreFirst { psbt = try process(psbt) }
        #expect(psbt.inputs[0].musig2PubNonces.count == 2)
        #expect(psbt.inputs[0].musig2PubNonces.keys.allSatisfy { $0.aggregate == context.signingKey })
        #expect(throws: (any Error).self) {
            var incomplete = psbt
            _ = try vault.finalizeSpend(&incomplete, knownUTXOs: [utxo],
                                       ownedOutputCoordinates: coordinates, chainTip: tip)
        }
        try vault.muSig2Sign(&psbt, input: 0, context: context, master: ourMaster,
                            secretNonces: &secretNonces, knownUTXOs: [utxo],
                            ownedOutputCoordinates: coordinates, chainTip: tip)
        #expect(secretNonces.values.allSatisfy { $0.allSatisfy { $0 == 0 } })
        psbt = try process(psbt)
        #expect(psbt.inputs[0].musig2PartialSigs.count == 2)
        try vault.muSig2Aggregate(&psbt, input: 0, context: context, knownUTXOs: [utxo],
                                 ownedOutputCoordinates: coordinates, chainTip: tip)
        let transaction = try vault.finalizeSpend(&psbt, knownUTXOs: [utxo],
                                                  ownedOutputCoordinates: coordinates, chainTip: tip)
        #expect(transaction.inputs[0].witness.count == 1)
        #expect(transaction.inputs[0].witness[0].count == 64)
        let txid = try BitcoinCLI.run(["sendrawtransaction", transaction.serialized(includeWitness: true).hex])
        _ = try await SignetMiner.mineOntoTip(payingTo: payout)
        let confirmed = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        #expect(try BitcoinCLI.int(confirmed, "confirmations") >= 1)
        trace("confirmed one-signature payment; Core first=\(coreFirst)")
    }

}

@Test("Core fixture preserves base58 keys ending in h", arguments: ["h", "'"])
func coreDescriptorKeyPreservesBase58(hardened: String) throws {
    let key = "tpubDDChux5N2nzqQBFzaBdidpdEGspdKEmRwi7gQdbqpnHvAviVZxikms3ZjaSQVLmnFaopeDnoBDdRdocHBBnw2K7AbiQLJLdnuQX1cbTPYFh"
    let input = "tr([e11008c1/86\(hardened)/1\(hardened)/0\(hardened)]\(key)/0/*)"
    let expression = try CoreSigner.keyExpression(from: input) + "/<0;1>/*"
    #expect(expression == "[e11008c1/86'/1'/0']\(key)/<0;1>/*")
    #expect(try Descriptor("tr(\(expression))").serialized().contains(expression))
}
