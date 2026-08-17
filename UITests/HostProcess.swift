import Foundation

/// Spawning host processes from inside the iOS-simulator test runner.
/// Foundation's `Process` is iOS-unavailable even though the simulator runs
/// macOS binaries fine, so this goes through posix_spawn directly (the
/// simulator applies no sandbox to the test runner).
enum HostProcess {
    struct SpawnError: Error, CustomStringConvertible {
        let path: String
        let code: Int32
        var description: String { "posix_spawn(\(path)) failed: errno \(code)" }
    }

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `path` with `arguments`, feeding `input` to stdin; waits for exit
    /// and collects stdout/stderr. Throws on spawn failure only — check
    /// `result.status` for the command's own exit code.
    @discardableResult
    static func run(_ path: String, _ arguments: [String] = [], input: Data? = nil) throws -> Result {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        pipe(&outPipe)
        pipe(&errPipe)
        pipe(&inPipe)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])
        posix_spawn_file_actions_addclose(&actions, inPipe[1])
        defer { posix_spawn_file_actions_destroy(&actions) }

        var argv = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid = pid_t()
        // envp is deliberately null: every caller passes an absolute `path`,
        // so no child here needs a PATH, and there is no correct environment
        // to inherit. `xcodebuild test` does not forward its environment into
        // the simulator test runner, and what the runner does carry is the
        // simulator's own DYLD_* — handing that to a native host binary like
        // bitcoin-cli would point dyld at the simulator runtime's dylibs.
        // Node configuration reaches the child as explicit arguments (see
        // BitcoinCLI.run), never as environment. Refs #31.
        let rc = posix_spawn(&pid, path, &actions, nil, &argv, nil)
        // Parent ends of the child's pipes.
        close(outPipe[1])
        close(errPipe[1])
        close(inPipe[0])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            close(inPipe[1])
            throw SpawnError(path: path, code: rc)
        }

        if let input, !input.isEmpty {
            _ = input.withUnsafeBytes { write(inPipe[1], $0.baseAddress!, input.count) }
        }
        close(inPipe[1])

        // Outputs are small (CLI JSON / single lines) — sequential reads to
        // EOF cannot deadlock against the 64 KB pipe buffers here.
        let outData = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        let errData = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true).readDataToEndOfFile()

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        return Result(status: exitCode,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}
