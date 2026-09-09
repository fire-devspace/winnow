import Foundation
import WalletCore

enum InspectionCommand {
    static let usage = """
    Offline inspection using the app's parsers:
      winnow-debug inspect tx <hex>
      winnow-debug inspect psbt <base64>
      winnow-debug inspect descriptor <descriptor> [mainnet|signet|regtest]
    Descriptor inspection shows index 0 for each multipath choice.
    """

    static func render(_ arguments: [String]) throws -> String {
        guard let kind = arguments.first, !["help", "--help", "-h"].contains(kind) else {
            return usage
        }
        guard arguments.count >= 2 else { throw DebugError.usage(usage) }
        let value: [String: Any]
        switch kind {
        case "tx" where arguments.count == 2:
            guard let data = Data(hex: arguments[1]) else { throw DebugError.usage("transaction needs hex") }
            value = transaction(try Transaction.decode(data))
        case "psbt" where arguments.count == 2:
            let psbt = try PSBT(base64: arguments[1])
            value = [
                "transaction": transaction(try psbt.unsignedTransaction()),
                "signing": psbt.inputs.map { input in
                    ["hasWitnessUTXO": input.witnessUTXO != nil,
                     "tapKeySig": input.tapKeySignature != nil,
                     "tapScriptSigs": input.tapScriptSignatures.count] as [String: Any]
                },
            ]
        case "descriptor" where arguments.count <= 3:
            let network = arguments.count == 3 ? arguments[2] : "signet"
            guard let chain = BitcoinNetwork(rawValue: network) else { throw DebugError.usage(usage) }
            let outputs = try Descriptor(arguments[1]).derived(index: 0, network: chain)
            value = ["network": network, "index": 0, "outputs": outputs.enumerated().map { choice, output in
                ["choice": choice, "scriptPubKey": output.scriptPubKey.hex, "address": output.address] as [String: Any]
            }]
        default: throw DebugError.usage(usage)
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func transaction(_ tx: Transaction) -> [String: Any] {
        ["txid": tx.txid.displayHex, "version": tx.version, "locktime": tx.locktime,
         "vsize": TransactionBuilder.vsize(of: tx),
         "inputs": tx.inputs.map { input in
             ["txid": input.previousOutput.txid.displayHex, "vout": input.previousOutput.vout,
              "sequence": input.sequence, "witnessItems": input.witness.count] as [String: Any]
         },
         "outputs": tx.outputs.map { ["value": $0.value, "scriptPubKey": $0.scriptPubKey.hex] as [String: Any] }]
    }
}
