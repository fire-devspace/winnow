import Foundation

struct DebugCommandResult: Sendable, Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct DebugSystem: Sendable {
    let repository: URL

    @discardableResult
    func run(_ executable: String, _ arguments: [String],
                    allowFailure: Bool = false) throws -> DebugCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repository
        // Regular files avoid the classic Process/Pipe deadlock where a
        // verbose command (notably xcodebuild) fills the pipe while this
        // synchronous caller waits for it to exit.
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "winnow-debug-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appending(path: "stdout")
        let errorURL = temporary.appending(path: "stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try output.synchronize()
        try error.synchronize()
        let result = DebugCommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
        if !allowFailure, result.status != 0 {
            throw DebugError.command(([executable] + arguments).joined(separator: " "),
                                           result.status, result.stdout + result.stderr)
        }
        return result
    }

    func doctor() -> [(String, Bool, String)] {
        var checks: [(String, Bool, String)] = []
        let project = repository.appending(path: "project.yml")
        checks.append(("App project", FileManager.default.fileExists(atPath: project.path), project.path))
        for (name, executable, arguments) in [
            ("Swift", "/usr/bin/xcrun", ["swift", "--version"]),
            ("Xcode", "/usr/bin/xcodebuild", ["-version"]),
            ("Simulator", "/usr/bin/xcrun", ["simctl", "list", "devices", "available"]),
            ("Git", "/usr/bin/git", ["rev-parse", "--show-toplevel"]),
        ] {
            let result = try? run(executable, arguments, allowFailure: true)
            checks.append((name, result?.status == 0,
                           (result?.stdout ?? result?.stderr ?? "unavailable")
                               .split(separator: "\n").first.map(String.init) ?? "unavailable"))
        }
        return checks
    }

    /// Collect local diagnostics without creating wallets, recording video,
    /// copying secrets, or producing a publication artifact.
    func diagnostics(_ options: DiagnosticsOptions) throws {
        let destination = options.destination
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try run("/usr/bin/xcrun", ["simctl", "io", options.simulator, "screenshot",
                                  destination.appending(path: "screenshot.png").path])
        let log = try run("/usr/bin/xcrun", [
            "simctl", "spawn", options.simulator, "log", "show", "--style", "compact", "--last", "10m",
            "--predicate", "process == 'WinnowApp'",
        ], allowFailure: true)
        try (log.stdout + log.stderr).write(to: destination.appending(path: "app.log"),
                                           atomically: true, encoding: .utf8)
        guard let runID = options.runID else { return }
        let result = try run("/usr/bin/xcrun", ["simctl", "get_app_container", options.simulator,
                                               "com.btcswift.app", "data"])
        let container = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let store = container.appending(path: "Library/Application Support/BTCSwiftE2E-\(runID)")
        for name in ["story-events.jsonl", "signet/peers.json"] {
            let source = store.appending(path: name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try Data(contentsOf: source).write(to: destination.appending(path: source.lastPathComponent),
                                               options: .atomic)
        }
    }
}
