import Darwin
import Foundation

@main
enum WinnowDebug {
    static func main() async {
        do {
            try await execute(Array(CommandLine.arguments.dropFirst()))
        } catch let error as SoakError {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func execute(_ arguments: [String]) async throws {
        guard let command = arguments.first else { return print(usageText) }
        switch command {
        case "help", "--help", "-h": print(usageText)
        case "inspect": print(try InspectionCommand.render(Array(arguments.dropFirst())))
        case "generate": try await WinnowGenerate.execute(Array(arguments.dropFirst()))
        case "soak": try await SoakCommand.execute(Array(arguments.dropFirst()))
        case "doctor":
            var failed = false
            for (name, passed, detail) in system.doctor() {
                print("\(passed ? "✓" : "✗") \(name): \(detail)")
                failed = failed || !passed
            }
            if failed { throw DebugError.usage("GUI debugging environment checks failed") }
        case "diagnostics":
            if arguments.count == 2, ["help", "--help", "-h"].contains(arguments[1]) {
                return print(usageText)
            }
            let options = try DiagnosticsOptions(arguments: Array(arguments.dropFirst()))
            try system.diagnostics(options)
            print("Diagnostics saved in \(options.destination.path)")
        default: throw DebugError.usage("unknown command \(command)\n\n\(usageText)")
        }
    }

    private static var system: DebugSystem {
        DebugSystem(repository: URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["WINNOW_DEBUG_REPOSITORY"]
                ?? FileManager.default.currentDirectoryPath))
    }

    static let usageText = """
    Winnow GUI and network debugging

      scripts/winnow-debug inspect --help
      scripts/winnow-debug doctor
      scripts/winnow-debug diagnostics --simulator UDID --out DIR [--run E2E_RUN_ID]
      scripts/winnow-debug generate --help
      scripts/winnow-debug generate fallback-peers [--out PATH] [--target 96] [--floor 24]
      scripts/winnow-debug generate checkpoint <headers.bin> [--height H] [--vector-out PATH]
      scripts/winnow-debug soak --help
      scripts/winnow-debug soak [--network signet|mainnet] [--minutes N] [--out PATH] [--state DIR]
    """
}

enum DebugError: LocalizedError {
    case usage(String)
    case command(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case let .usage(message): message
        case let .command(command, status, output): "\(command) failed (\(status)): \(output)"
        }
    }
}

struct DiagnosticsOptions {
    let simulator: String
    let destination: URL
    let runID: String?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard ["--simulator", "--out", "--run"].contains(option),
                  values[option] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].isEmpty, !arguments[index + 1].hasPrefix("--") else {
                throw DebugError.usage("invalid diagnostics option \(option)\n\n\(WinnowDebug.usageText)")
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        guard let simulator = values["--simulator"], let out = values["--out"] else {
            throw DebugError.usage("diagnostics needs --simulator and --out")
        }
        if let runID = values["--run"], !runID.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) {
            throw DebugError.usage("--run must be a single E2E storage name")
        }
        self.simulator = simulator
        destination = URL(fileURLWithPath: out)
        runID = values["--run"]
    }
}
