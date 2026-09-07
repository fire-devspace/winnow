import WalletCore
import Foundation
import Testing
@testable import WinnowDebug

@Suite("Operator command dispatch", .timeLimit(.minutes(1)))
struct OperatorCLITests {
    @Test("operator help needs no story run, simulator, network, or header file")
    func help() async throws {
        for command in [["generate"], ["generate", "--help"], ["soak", "--help"], ["soak", "help"]] {
            try await WinnowDebug.execute(command)
        }
    }

    @Test("operator errors come from their own parser without requiring a story run")
    func dispatch() async {
        await #expect(throws: GenerateError.self) {
            try await WinnowDebug.execute(["generate", "nope"])
        }
        await #expect(throws: GenerateError.self) {
            try await WinnowDebug.execute(["generate", "checkpoint"])
        }
        await #expect(throws: SoakError.self) {
            try await WinnowDebug.execute(["soak", "--peers", "0"])
        }
    }

    @Test("soak options preserve the public-signet defaults and all overrides")
    func soakOptions() throws {
        let defaults = try SoakOptions(arguments: [])
        #expect(defaults.network.magic == NetworkParams.signet.magic)
        #expect(defaults.samplePeriod == .seconds(60))
        #expect(defaults.runFor == nil)
        #expect(defaults.out == nil && defaults.stateDirectory == nil)
        #expect(defaults.startHeight == 0 && defaults.peerCount == 3 && defaults.watchScriptCount == 25)
        let custom = try SoakOptions(arguments: [
            "--network", "mainnet", "--minutes", "2", "--sample-seconds", "5",
            "--out", "/tmp/soak.jsonl", "--state", "/tmp/soak-state",
            "--start-height", "900000", "--peers", "4"
        ])
        #expect(custom.network.magic == NetworkParams.mainnet.magic)
        #expect(custom.runFor == .seconds(120) && custom.samplePeriod == .seconds(5))
        #expect(custom.out?.path == "/tmp/soak.jsonl")
        #expect(custom.stateDirectory?.path == "/tmp/soak-state")
        #expect(custom.startHeight == 900000 && custom.peerCount == 4)
        let unlimited = try SoakOptions(arguments: ["--minutes", "0"])
        #expect(unlimited.runFor == nil)
    }

    @Test("invalid soak options fail before opening files or connecting peers", arguments: [
        ["--network", "regtest"], ["--minutes", "-1"], ["--sample-seconds", "0"],
        ["--start-height", "-1"], ["--peers", "0"], ["--out"], ["--unknown"]
    ])
    func invalidSoakOptions(arguments: [String]) {
        #expect(throws: SoakError.self) { try SoakOptions(arguments: arguments) }
    }
}
