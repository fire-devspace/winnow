import Foundation
import Testing
import WalletCore
@testable import WinnowDebug

@Suite("Offline inspection")
struct InspectionTests {
    @Test("transaction and PSBT inspection preserve amounts, outpoints and signing state")
    func payment() throws {
        let tx = Transaction(version: 2, inputs: [
            .init(previousOutput: .init(txid: Data(repeating: 0x12, count: 32), vout: 3),
                  scriptSig: Data(), sequence: 0xFFFF_FFFD)
        ], outputs: [.init(value: 4_000, scriptPubKey: Data([0x51]))], locktime: 42)
        let inspected = try object(["tx", tx.serialized(includeWitness: true).hex])
        #expect(inspected["locktime"] as? Int == 42)
        let inputs = try #require(inspected["inputs"] as? [[String: Any]])
        #expect(inputs.first?["vout"] as? Int == 3)
        let outputs = try #require(inspected["outputs"] as? [[String: Any]])
        #expect(outputs.first?["value"] as? Int == 4_000)
        let psbt = try PSBT(unsignedTx: tx, inputs: [
            .init(spentOutput: .init(amount: 5_000, scriptPubKey: Data([0x51])))
        ], outputs: [.init()])
        let parsed = try object(["psbt", psbt.base64])
        let transaction = try #require(parsed["transaction"] as? [String: Any])
        #expect(transaction["txid"] as? String == inspected["txid"] as? String)
        let signing = try #require(parsed["signing"] as? [[String: Any]])
        #expect(signing.first?["hasWitnessUTXO"] as? Bool == true)
        #expect(signing.first?["tapKeySig"] as? Bool == false)
    }

    @Test("descriptor inspection uses the derived address without applying a second Taproot tweak")
    func descriptor() throws {
        let account = "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ"
        let parsed = try object(["descriptor", "tr(" + account + "/<0;1>/*)", "mainnet"])
        let outputs = try #require(parsed["outputs"] as? [[String: Any]])
        #expect(outputs.count == 2)
        #expect(outputs.first?["address"] as? String == "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")
        // The prefix follows the network named on the command line, not the
        // key's version bytes: the same script under regtest is a bcrt1 address.
        let regtest = try object(["descriptor", "tr(" + account + "/<0;1>/*)", "regtest"])
        let regtestOutputs = try #require(regtest["outputs"] as? [[String: Any]])
        #expect(regtestOutputs.first?["scriptPubKey"] as? String == outputs.first?["scriptPubKey"] as? String)
        #expect((regtestOutputs.first?["address"] as? String)?.hasPrefix("bcrt1p") == true)
    }

    @Test("invalid input and retired signing commands fail", arguments: [
        ["tx", "nope"], ["psbt", "nope"], ["descriptor", "nope"], ["tx", "00", "extra"],
        ["descriptor", "rawtr(00)", "testnet"], ["musig-sign-psbt", "anything"], ["tx"]
    ])
    func invalid(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try InspectionCommand.render(arguments) }
    }

    private func object(_ arguments: [String]) throws -> [String: Any] {
        let text = try InspectionCommand.render(arguments)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
