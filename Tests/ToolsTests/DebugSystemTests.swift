import Foundation
import Testing
@testable import WinnowDebug

@Suite("GUI debugging", .timeLimit(.minutes(1)))
struct DebugSystemTests {
    @Test("verbose child commands cannot deadlock the debug runner")
    func commandOutputIsDrained() throws {
        let repository = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let input = repository.appending(path: "large-output.txt")
        let data = Data(repeating: 0x78, count: 1_000_000)
        try data.write(to: input)
        let result = try DebugSystem(repository: repository).run(
            "/bin/sh", ["-c", "cat \"$1\"; cat \"$1\" >&2", "debug-output-test", input.path])
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == data.count)
        #expect(result.stderr.utf8.count == data.count)
    }

    @Test("diagnostics require an explicit simulator and output directory")
    func options() throws {
        let options = try DiagnosticsOptions(arguments: [
            "--simulator", "booted", "--out", "/tmp/winnow-debug", "--run", "isolated-test"
        ])
        #expect(options.simulator == "booted")
        #expect(options.destination.path == "/tmp/winnow-debug")
        #expect(options.runID == "isolated-test")
        for arguments in [[], ["--simulator", "booted"],
                          ["--simulator", "booted", "--out"],
                          ["--simulator", "booted", "--out", "/tmp", "--run", "../wallet"]] {
            #expect(throws: DebugError.self) { try DiagnosticsOptions(arguments: arguments) }
        }
    }

    @Test("retired demo and publication commands are rejected")
    func retiredCommands() async {
        for command in ["start", "resume", "capture", "review-media", "finish", "launch-role", "keys"] {
            await #expect(throws: DebugError.self) { try await WinnowDebug.execute([command]) }
        }
    }
}
