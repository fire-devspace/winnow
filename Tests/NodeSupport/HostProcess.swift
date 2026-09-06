import Foundation

/// Spawning host processes from inside the iOS-simulator test runner.
/// Foundation's `Process` is iOS-unavailable even though the simulator runs
/// macOS binaries fine, so this goes through posix_spawn directly (the
/// simulator applies no sandbox to the test runner).
enum HostProcess {
    // Single-writer storage, synchronized by the group join in run().
    private final class PipeOutput: @unchecked Sendable {
        var data = Data()
    }

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

        // Concurrent tests must not inherit each other's open pipe ends.
        // Only descriptors explicitly set up by our file actions survive exec.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        defer { posix_spawnattr_destroy(&attributes) }

        var pid = pid_t()
        // envp is deliberately null: every caller passes an absolute `path`,
        // so no child here needs a PATH, and there is no correct environment
        // to inherit. `xcodebuild test` does not forward its environment into
        // the simulator test runner, and what the runner does carry is the
        // simulator's own DYLD_* — handing that to a native host binary like
        // bitcoin-cli would point dyld at the simulator runtime's dylibs.
        // Node configuration reaches the child as explicit arguments (see
        // BitcoinCLI.run), never as environment. Refs #31.
        let rc = posix_spawn(&pid, path, &actions, &attributes, &argv, nil)
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

        // Drain both streams before writing input or waiting: Core can return
        // JSON larger than a pipe buffer. Each output box has one writer and
        // is read only after DispatchGroup joins that writer.
        let output = PipeOutput()
        let errors = PipeOutput()
        let group = DispatchGroup()
        let outFD = outPipe[0], errFD = errPipe[0]
        // Dedicated readers cannot be starved by synchronous tests occupying
        // every thread in Swift's shared cooperative pool on small runners.
        group.enter()
        Thread.detachNewThread {
            output.data = FileHandle(fileDescriptor: outFD, closeOnDealloc: true).readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        Thread.detachNewThread {
            errors.data = FileHandle(fileDescriptor: errFD, closeOnDealloc: true).readDataToEndOfFile()
            group.leave()
        }
        if let input, !input.isEmpty {
            input.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(inPipe[1], bytes.baseAddress! + offset, bytes.count - offset)
                    if count > 0 { offset += count }
                    else if errno != EINTR { break }
                }
            }
        }
        close(inPipe[1])
        group.wait()

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        return Result(status: exitCode,
                      stdout: String(decoding: output.data, as: UTF8.self),
                      stderr: String(decoding: errors.data, as: UTF8.self))
    }
}
