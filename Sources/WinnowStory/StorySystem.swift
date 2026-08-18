import Darwin
import BitcoinP2P
import Foundation

public struct StoryCommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public enum StorySystemError: LocalizedError {
    case command(String, Int32, String)
    case noSimulator
    case appMissing(String)
    case recordingAlreadyRunning(String)
    case recordingNotRunning

    public var errorDescription: String? {
        switch self {
        case let .command(command, status, output): "\(command) failed (\(status)): \(output)"
        case .noSimulator: "No available iPhone simulator was found."
        case let .appMissing(path): "The built Winnow app was not found at \(path)."
        case let .recordingAlreadyRunning(stage): "A recording is already running for \(stage)."
        case .recordingNotRunning: "No story recording is running."
        }
    }
}

public struct StorySystem: Sendable {
    public let repository: URL

    public init(repository: URL) { self.repository = repository }

    @discardableResult
    public func run(_ executable: String, _ arguments: [String],
                    environment: [String: String] = [:], allowFailure: Bool = false) throws -> StoryCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, new in new }
        process.environment = processEnvironment
        process.currentDirectoryURL = repository
        // Regular files avoid the classic Process/Pipe deadlock where a
        // verbose command (notably xcodebuild) fills the pipe while this
        // synchronous caller waits for it to exit.
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "winnow-story-command-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        let result = StoryCommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self))
        if !allowFailure, result.status != 0 {
            throw StorySystemError.command(([executable] + arguments).joined(separator: " "),
                                           result.status, result.stdout + result.stderr)
        }
        return result
    }

    public func environment() -> StoryEnvironment {
        let git = try? run("/usr/bin/git", ["rev-parse", "HEAD"])
        let status = try? run("/usr/bin/git", ["status", "--porcelain"])
        let swift = try? run("/usr/bin/xcrun", ["swift", "--version"])
        let xcode = try? run("/usr/bin/xcodebuild", ["-version"])
        return StoryEnvironment(
            gitCommit: git?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown",
            swiftVersion: swift?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown",
            xcodeVersion: xcode?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown",
            gitDirty: !(status?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    public func doctor() -> [(String, Bool, String)] {
        var checks: [(String, Bool, String)] = []
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
        let bitcoin = (try? run("/usr/bin/pgrep", ["-x", "bitcoind"], allowFailure: true))
        let running = bitcoin?.status == 0
        checks.append(("Local bitcoind not required", true,
                       running ? "running, but this story will not contact it" : "not running"))
        return checks
    }

    /// Returns the simulator dedicated to this story run, creating it when
    /// necessary. The runner never borrows a developer's already-booted phone:
    /// wallet state, Keychain items, screenshots, and device settings therefore
    /// stay inside one explicitly named disposable device.
    public func selectSimulator(runID: String) throws -> (udid: String, name: String, runtime: String) {
        let storyName = "Winnow Story \(runID)"
        let result = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"])
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]]
        else { throw StorySystemError.noSimulator }
        let candidates = devices.flatMap { runtime, runtimeDevices in
            runtimeDevices.map { (runtime: runtime, device: $0) }
        }.filter {
            ($0.device["isAvailable"] as? Bool) == true
                && (($0.device["name"] as? String)?.hasPrefix("iPhone") ?? false)
        }
        if let existing = candidates.first(where: {
            ($0.device["name"] as? String) == storyName
        }), let udid = existing.device["udid"] as? String {
            return (udid, storyName, existing.runtime)
        }

        let runtimeResult = try run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "available", "-j"])
        guard let runtimeData = runtimeResult.stdout.data(using: .utf8),
              let runtimeObject = try JSONSerialization.jsonObject(with: runtimeData) as? [String: Any],
              let runtimes = runtimeObject["runtimes"] as? [[String: Any]],
              let runtime = runtimes.filter({ entry in
                  (entry["isAvailable"] as? Bool) != false
                      && ((entry["identifier"] as? String)?.contains(".iOS-") ?? false)
              }).sorted(by: { lhs, rhs in
                  (lhs["version"] as? String ?? "0").compare(
                      rhs["version"] as? String ?? "0", options: .numeric) == .orderedDescending
              }).first,
              let runtimeID = runtime["identifier"] as? String
        else { throw StorySystemError.noSimulator }

        let typeResult = try run("/usr/bin/xcrun", ["simctl", "list", "devicetypes", "-j"])
        guard let typeData = typeResult.stdout.data(using: .utf8),
              let typeObject = try JSONSerialization.jsonObject(with: typeData) as? [String: Any],
              let deviceTypes = typeObject["devicetypes"] as? [[String: Any]]
        else { throw StorySystemError.noSimulator }
        let preferredNames = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"]
        let phoneTypes = deviceTypes.filter {
            ($0["name"] as? String)?.hasPrefix("iPhone") == true
        }
        let deviceType = preferredNames.compactMap { preferred in
            phoneTypes.first { ($0["name"] as? String) == preferred }
        }.first ?? phoneTypes.first
        guard let deviceTypeID = deviceType?["identifier"] as? String else {
            throw StorySystemError.noSimulator
        }

        let created = try run("/usr/bin/xcrun", [
            "simctl", "create", storyName, deviceTypeID, runtimeID,
        ])
        let udid = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else { throw StorySystemError.noSimulator }
        return (udid, storyName, runtimeID)
    }

    /// Finds a previously recorded simulator only if it is still installed and
    /// available. A deleted run device is recreated by `selectSimulator` on
    /// resume instead of turning a recoverable preflight into a dead run.
    public func simulator(udid: String) throws -> (udid: String, name: String, runtime: String)? {
        let result = try run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"])
        guard let data = result.stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]]
        else { throw StorySystemError.noSimulator }
        for (runtime, runtimeDevices) in devices {
            guard let device = runtimeDevices.first(where: {
                ($0["udid"] as? String) == udid && ($0["isAvailable"] as? Bool) == true
            }), let name = device["name"] as? String else { continue }
            return (udid, name, runtime)
        }
        return nil
    }

    public func boot(_ udid: String) throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "boot", udid], allowFailure: true)
        _ = try run("/usr/bin/open", ["-a", "Simulator"], allowFailure: true)
        _ = try run("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
    }

    public func buildAndInstall(udid: String) throws {
        let project = repository.appending(path: "WinnowApp.xcodeproj")
        if !FileManager.default.fileExists(atPath: project.path) {
            _ = try run("/usr/bin/env", ["xcodegen"])
        }
        let derived = repository.appending(path: ".build/winnow-story/DerivedData")
        // swift-secp256k1's source-copy plugin preserves read-only bits. On a
        // second Xcode build those stale generated copies can emit permission
        // errors while Xcode still exits zero. Remove only that derived plugin
        // output so every story build regenerates it from package sources.
        let pluginOutput = derived.appending(
            path: "Build/Intermediates.noindex/BuildToolPluginIntermediates",
            directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: pluginOutput.path) {
            try FileManager.default.removeItem(at: pluginOutput)
        }
        let build = try run("/usr/bin/xcodebuild", [
            "-project", project.path, "-scheme", "WinnowApp", "-destination", "id=\(udid)",
            "-derivedDataPath", derived.path, "-skipPackagePluginValidation", "-skipMacroValidation",
            "build",
        ])
        if (build.stdout + build.stderr).localizedCaseInsensitiveContains("permission denied") {
            throw StorySystemError.command("xcodebuild", build.status,
                                           "generated package files were not refreshed: permission denied")
        }
        let app = derived.appending(path: "Build/Products/Debug-iphonesimulator/WinnowApp.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw StorySystemError.appMissing(app.path)
        }
        _ = try run("/usr/bin/xcrun", ["simctl", "install", udid, app.path])
    }

    public func launch(udid: String, runID: String, personaID: String, seedHex: String,
                       reset: Bool = false, clipboard: String? = nil,
                       initialTab: String? = nil) throws {
        var environment = [
            "SIMCTL_CHILD_WINNOW_E2E": "1",
            "SIMCTL_CHILD_WINNOW_E2E_RUN": "\(runID)-\(personaID)",
            "SIMCTL_CHILD_WINNOW_E2E_ENTROPY": String(seedHex.prefix(32)),
            "SIMCTL_CHILD_WINNOW_STORY_PERSONA": personaID,
            "SIMCTL_CHILD_WINNOW_E2E_NETWORK": "signet",
            "SIMCTL_CHILD_WINNOW_E2E_DEVICE_AUTH": "1",
        ]
        if reset { environment["SIMCTL_CHILD_WINNOW_E2E_RESET"] = "1" }
        if let clipboard { environment["SIMCTL_CHILD_WINNOW_E2E_CLIPBOARD"] = clipboard }
        if let initialTab { environment["SIMCTL_CHILD_WINNOW_E2E_TAB"] = initialTab }
        _ = try run("/usr/bin/xcrun", ["simctl", "launch", "--terminate-running-process", udid,
                                        "com.btcswift.app"], environment: environment)
    }

    public func terminate(udid: String) {
        _ = try? run("/usr/bin/xcrun", ["simctl", "terminate", udid, "com.btcswift.app"],
                     allowFailure: true)
    }

    /// Copies only the validated public signet header snapshot between
    /// isolated persona stores. Wallet databases, keychain material,
    /// filters, and broadcast state are never copied.
    @discardableResult
    public func shareSignetHeaders(udid: String, runID: String,
                                   destinationPersonaID: String) throws -> Bool {
        guard destinationPersonaID != "sofia" else { return false }
        let container = try appDataContainer(udid: udid)
        let support = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let destinationDirectory = support.appending(
            path: "BTCSwiftE2E-\(runID)-\(destinationPersonaID)/signet",
            directoryHint: .isDirectory)
        let destination = destinationDirectory.appending(path: "headers.bin")
        // An existing isolated role already loaded (and therefore validated)
        // its own snapshot. Let the app validate it again on launch instead of
        // blocking every role switch on a second full source-chain load.
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }

        let source = support.appending(path: "BTCSwiftE2E-\(runID)-sofia/signet/headers.bin")
        guard FileManager.default.fileExists(atPath: source.path) else { return false }

        // Loading the file verifies its size, genesis, proof of work, and
        // linkage. A damaged snapshot is never propagated.
        _ = try HeaderChain(params: .signet, storageURL: source)
        try FileManager.default.createDirectory(at: destinationDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: destination)
        _ = try HeaderChain(params: .signet, storageURL: destination)
        return true
    }

    public func collectDiagnostics(udid: String, runID: String, personaID: String,
                                   checkpoint: StoryCheckpoint, destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let prefix = "\(checkpoint.rawValue)-\(timestamp)"
        try screenshot(udid: udid, destination: destination.appending(path: "\(prefix).png"))

        let log = try run("/usr/bin/xcrun", [
            "simctl", "spawn", udid, "log", "show", "--style", "compact", "--last", "10m",
            "--predicate", "process == 'WinnowApp'",
        ], allowFailure: true)
        try (log.stdout + log.stderr).write(
            to: destination.appending(path: "\(prefix)-app.log"), atomically: true, encoding: .utf8)

        let container = try appDataContainer(udid: udid)
        let store = container.appending(
            path: "Library/Application Support/BTCSwiftE2E-\(runID)-\(personaID)")
        for name in ["story-events.jsonl", "signet/peers.json"] {
            let source = store.appending(path: name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let suffix = URL(fileURLWithPath: name).lastPathComponent
            try FileManager.default.copyItem(at: source,
                                             to: destination.appending(path: "\(prefix)-\(suffix)"))
        }
    }

    public func collectRunEvidence(udid: String, runID: String,
                                   destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let container = try appDataContainer(udid: udid)
        let support = container.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        for personaID in ["sofia", "elena", "sofia-replacement"] {
            let store = support.appending(path: "BTCSwiftE2E-\(runID)-\(personaID)")
            for (sourceName, destinationName) in [
                ("story-events.jsonl", "\(personaID)-events.jsonl"),
                ("signet/peers.json", "\(personaID)-public-peers.json"),
            ] {
                let source = store.appending(path: sourceName)
                let destinationURL = destination.appending(path: destinationName)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: source, to: destinationURL)
            }
        }
    }

    /// Latest safe peer-count event emitted by one isolated app role. Missing
    /// journals simply mean the app has not reached that state yet.
    public func publicPeerCount(udid: String, runID: String,
                                personaID: String = "sofia") throws -> Int {
        let container = try appDataContainer(udid: udid)
        let journal = container.appending(
            path: "Library/Application Support/BTCSwiftE2E-\(runID)-\(personaID)/story-events.jsonl")
        guard let text = try? String(contentsOf: journal, encoding: .utf8) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(StoryEvent.self, from: Data(line.utf8))
        }.filter { $0.name == "peers.status" }
            .compactMap { $0.fields["connected"].flatMap(Int.init) }
            .last ?? 0
    }

    /// Returns the validated signet snapshot used by one isolated story
    /// persona. Callers still construct `HeaderChain`, which authenticates
    /// the file before using it as public transaction evidence.
    public func signetHeadersURL(udid: String, runID: String,
                                 personaID: String = "sofia") throws -> URL {
        let container = try appDataContainer(udid: udid)
        return container.appending(
            path: "Library/Application Support/BTCSwiftE2E-\(runID)-\(personaID)/signet/headers.bin")
    }

    private func appDataContainer(udid: String) throws -> URL {
        let result = try run("/usr/bin/xcrun", [
            "simctl", "get_app_container", udid, "com.btcswift.app", "data",
        ])
        return URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                   isDirectory: true)
    }

    public func screenshot(udid: String, destination: URL) throws {
        _ = try run("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", destination.path])
    }

    public func startRecording(udid: String, destination: URL) throws -> Int32 {
        let process = Process()
        // `capture` is a short-lived CLI invocation while recording spans two
        // invocations. Ignore the launcher's SIGHUP so simctl survives after
        // the first command exits; the second invocation sends SIGINT to this
        // same PID, which lets simctl flush a valid movie atom.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/usr/bin/xcrun", "simctl", "io", udid, "recordVideo",
                             "--codec=h264", "--force", destination.path]
        process.currentDirectoryURL = repository
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process.processIdentifier
    }

    public func stopRecording(pid: Int32) throws {
        guard kill(pid, SIGINT) == 0 || errno == ESRCH else {
            throw StorySystemError.command("kill \(pid)", Int32(errno), String(cString: strerror(errno)))
        }
        // Give simctl time to flush the movie atom before the caller scans or
        // moves the artifact.
        Thread.sleep(forTimeInterval: 1.0)
    }

    public func isAlive(pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
