import BitcoinCore
import WalletCore
import Foundation
import P256K

/// The library's scriptable face: offline primitives over the same public
/// API the wallet uses, one subcommand per question. No network, no keys
/// unless handed one on the command line, no dependencies beyond the
/// library itself — this is a dev tool and an audit aid, not a wallet.
///
///   btc-swift derive <descriptor> [--network signet|mainnet] [--chain 0|1] [--count N]
///   btc-swift decode-tx <hex>
///   btc-swift decode-psbt <base64>
///   btc-swift combine-psbt <base64> <base64...>
///   btc-swift finalize-psbt <base64>
///   btc-swift filter-contains <filter-hex> <block-hash-hex> <script-hex...>
///   btc-swift musig-xpub <compressed-key-hex> <compressed-key-hex...>
///   btc-swift musig-sign-psbt <base64> --secrets <hex,hex...> [--input 0]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("btc-swift: " + message + "\n").utf8))
    exit(1)
}

func flag(_ name: String, in args: inout [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index ... index + 1)
    return value
}

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else { fail("could not encode output") }
    print(text)
}

func txObject(_ tx: Transaction) -> [String: Any] {
    [
        "txid": tx.txid.displayHex,
        "version": tx.version,
        "locktime": tx.locktime,
        "inputs": tx.inputs.map { input in
            [
                "txid": input.previousOutput.txid.displayHex,
                "vout": input.previousOutput.vout,
                "sequence": input.sequence,
                "witnessItems": input.witness.count,
            ] as [String: Any]
        },
        "outputs": tx.outputs.map { output in
            [
                "value": output.value,
                "scriptPubKey": output.scriptPubKey.hex,
            ] as [String: Any]
        },
        "vsize": TransactionBuilder.vsize(of: tx),
    ]
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: btc-swift <derive|decode-tx|decode-psbt|combine-psbt|finalize-psbt|filter-contains> …")
}
arguments.removeFirst()

do {
    switch command {
    case "derive":
        let networkName = flag("--network", in: &arguments) ?? "signet"
        guard let network = BitcoinNetwork(rawValue: networkName) else {
            fail("unknown network \(networkName)")
        }
        let chain = Int(flag("--chain", in: &arguments) ?? "0") ?? 0
        let count = UInt32(flag("--count", in: &arguments) ?? "5") ?? 5
        guard let descriptorText = arguments.first else { fail("derive needs a descriptor") }
        let descriptor = try Descriptor(descriptorText)
        let hdNetwork: HDKey.Network = network == .mainnet ? .mainnet : .testnet
        let hrp = network == .mainnet ? "bc" : "tb"
        var rows: [[String: Any]] = []
        for index in 0 ..< count {
            let derived = try descriptor.derived(index: index, network: hdNetwork)[chain]
            let script = derived.scriptPubKey
            rows.append([
                "index": index,
                "scriptPubKey": script.hex,
                "address": (try? BIP86.address(internalKey: script.dropFirst(2), hrp: hrp)) ?? "",
            ])
        }
        emit(["descriptor": descriptorText, "network": networkName, "chain": chain,
              "derivations": rows])

    case "decode-tx":
        guard let hex = arguments.first, let data = Data(hex: hex) else {
            fail("decode-tx needs transaction hex")
        }
        emit(txObject(try Transaction.decode(data)))

    case "decode-psbt":
        guard let base64 = arguments.first, let psbt = try? PSBT(base64: base64) else {
            fail("decode-psbt needs a Base64 PSBT")
        }
        emit([
            "txVersion": psbt.txVersion,
            "inputs": psbt.inputs.enumerated().map { index, input in
                [
                    "index": index,
                    "previousTxid": input.previousTxid.map(\.displayHex) ?? "",
                    "vout": input.outputIndex ?? 0,
                    "hasWitnessUTXO": input.witnessUTXO != nil,
                    "tapKeySig": input.tapKeySignature != nil,
                    "tapScriptSigs": input.tapScriptSignatures.count,
                ] as [String: Any]
            },
            "outputs": psbt.outputs.map { output in
                [
                    "amount": output.amount ?? 0,
                    "script": output.script?.hex ?? "",
                ] as [String: Any]
            },
        ])

    case "combine-psbt":
        guard arguments.count >= 2 else { fail("combine-psbt needs two or more PSBTs") }
        var psbts = arguments.map { base64 -> PSBT in
            guard let psbt = try? PSBT(base64: base64) else { fail("bad PSBT") }
            return psbt
        }
        let first = psbts.removeFirst()
        print(try first.combined(with: psbts).base64)

    case "finalize-psbt":
        guard let base64 = arguments.first, var psbt = try? PSBT(base64: base64) else {
            fail("finalize-psbt needs a Base64 PSBT")
        }
        try psbt.finalize()
        print(try psbt.extractedTransaction().serialized(includeWitness: true).hex)

    case "filter-contains":
        guard arguments.count >= 3,
              let filterData = Data(hex: arguments[0]),
              let blockHash = Data(hex: arguments[1])
        else { fail("filter-contains <filter-hex> <block-hash-display-hex> <script-hex…>") }
        var reader = ByteReader(filterData)
        let n = UInt32(try reader.readVarInt())
        let filter = try GCSFilter(p: GCSFilter.defaultP, m: GCSFilter.defaultM,
                                   key: Data(Data(blockHash.reversed()).prefix(16)),
                                   n: n, encoded: reader.readBytes(reader.remaining))
        var results: [[String: Any]] = []
        for scriptHex in arguments.dropFirst(2) {
            guard let script = Data(hex: scriptHex) else { fail("bad script hex \(scriptHex)") }
            results.append(["script": scriptHex, "matches": filter.contains(script)])
        }
        emit(["results": results])

    case "musig-xpub":
        // The group's face: aggregate the members' compressed keys (BIP327),
        // wrap the aggregate as a BIP328 synthetic xpub, and print the
        // cosigner expression a vault accepts — paste it like any other key.
        guard arguments.count >= 2 else { fail("musig-xpub needs two or more compressed keys") }
        let members = arguments.map { hex -> Data in
            guard let key = Data(hex: hex), key.count == 33 else {
                fail("member keys must be 33-byte compressed hex")
            }
            return key
        }
        let aggregate = try MuSig.aggregate(members)
        let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregate)
        emit([
            "aggregateKey": aggregate.hex,
            "syntheticXpub": synthetic.serialized(network: .testnet),
            "cosignerExpression": "[\(String(format: "%08x", synthetic.fingerprint))]"
                + "\(synthetic.serialized(network: .testnet))/<0;1>/*",
        ])

    case "musig-sign-psbt":
        // Demo-grade group signer: both member secrets in one invocation —
        // a simulation of the two-round ceremony, not a wallet. Finds the
        // group's leaf key via the PSBT's own BIP371 derivation entries
        // (fingerprint match), rebuilds the BIP328 tweaks for that path,
        // runs BIP327's two rounds over the script-path sighash, and prints
        // the PSBT with the group's tap script signature attached.
        let secretsFlag = flag("--secrets", in: &arguments) ?? ""
        let inputIndex = Int(flag("--input", in: &arguments) ?? "0") ?? 0
        guard let base64 = arguments.first, let parsed = try? PSBT(base64: base64) else {
            fail("musig-sign-psbt needs a Base64 PSBT")
        }
        var psbt = parsed
        let secrets = secretsFlag.split(separator: ",").map { part -> Data in
            guard let secret = Data(hex: String(part)), secret.count == 32 else {
                fail("--secrets takes comma-separated 32-byte hex")
            }
            return secret
        }
        guard secrets.count >= 2 else { fail("a group needs two or more member secrets") }
        let memberKeys = try secrets.map {
            try P256K.Signing.PrivateKey(dataRepresentation: $0).publicKey.dataRepresentation
        }
        let aggregate = try MuSig.aggregate(memberKeys)
        let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregate)
        guard psbt.inputs.indices.contains(inputIndex),
              let leaf = psbt.inputs[inputIndex].tapLeafScripts.first else {
            fail("input \(inputIndex) has no tap leaf script")
        }
        // Our own leaf key and path, from the PSBT's derivation entries.
        guard let derivation = psbt.inputs[inputIndex].tapBIP32Derivation.first(where: {
            $0.value.masterFingerprint == synthetic.fingerprint
        }) else { fail("the PSBT names no key with the group's fingerprint") }
        let path = derivation.value.path
        guard path.count == 2, path.allSatisfy({ $0 < 0x8000_0000 }) else {
            fail("expected a two-step non-hardened path, got \(path)")
        }
        var tweaks: [Data] = []
        var step = synthetic
        for component in path {
            tweaks.append(MuSig.bip328Tweak(chainCode: step.chainCode,
                                            aggregatePublicKey: step.publicKey,
                                            index: component))
            step = try step.derived(path: "\(component)")
        }
        let spentOutputs = try psbt.spentOutputs()
        let tx = try psbt.unsignedTransaction()
        let sighash = try SighashBIP341.sighash(
            tx: tx, inputIndex: inputIndex, spentOutputs: spentOutputs, hashType: .default,
            scriptPath: .init(leafScript: Script(leaf.script), leafVersion: leaf.leafVersion))
        var nonces: [(secret: Data, public_: Data)] = []
        for (secret, publicKey) in zip(secrets, memberKeys) {
            let nonce = try MuSig.nonceGenerate(secretKey: secret, publicKey: publicKey,
                                                aggregateKey: Data(aggregate.dropFirst()),
                                                message: sighash)
            nonces.append((nonce.secretNonce, nonce.publicNonce))
        }
        let session = MuSig.Session(
            aggregateNonce: try MuSig.nonceAggregate(publicNonces: nonces.map(\.public_)),
            publicKeys: memberKeys, tweaks: tweaks,
            isXOnlyTweaks: tweaks.map { _ in false }, message: sighash)
        var partials: [Data] = []
        for (index, secret) in secrets.enumerated() {
            var secretNonce = nonces[index].secret
            let partial = try MuSig.partialSign(secretNonce: &secretNonce, secretKey: secret,
                                                session: session)
            guard try MuSig.partialVerify(partialSignature: partial, publicNonce: nonces[index].public_,
                                          publicKey: memberKeys[index], session: session) else {
                fail("member \(index + 1)'s partial signature failed verification")
            }
            partials.append(partial)
        }
        let signature = try MuSig.partialSigAggregate(partialSignatures: partials, session: session)
        psbt.inputs[inputIndex].pairs.append(PSBT.KeyValue(
            type: 0x14, keyData: Data(derivation.key) + leaf.leafHash, value: signature))
        print(psbt.base64)

    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("\(error)")
}
