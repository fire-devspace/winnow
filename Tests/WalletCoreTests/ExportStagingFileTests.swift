import Foundation
import Testing
@testable import WalletCore

@Suite("Export staging file")
struct ExportStagingFileTests {
    @Test("writes a unique path, replaces the previous file, and remove() deletes it")
    func uniqueWriteAndCleanup() throws {
        let staging = ExportStagingFile()
        defer { staging.remove() }

        let first = try staging.write("watch-only", suggestedName: "winnow-signet-73c5da0a.json")
        #expect(first.lastPathComponent == "winnow-signet-73c5da0a.json")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try String(contentsOf: first, encoding: .utf8) == "watch-only")
        var backup = try first.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backup.isExcludedFromBackup == true)

        let second = try staging.write("abandon abandon abandon", suggestedName: "winnow-signet-73c5da0a.json")
        #expect(second != first)
        #expect(second.lastPathComponent == "winnow-signet-73c5da0a.json")
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try String(contentsOf: second, encoding: .utf8) == "abandon abandon abandon")
        backup = try second.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(backup.isExcludedFromBackup == true)

        staging.remove()
        #expect(staging.url == nil)
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(!FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
    }

    @Test("a failed write deletes the new directory and leaves no staged URL")
    func failedWriteCleansUp() throws {
        let staging = ExportStagingFile()
        defer { staging.remove() }
        let previous = try staging.write("kept-only-until-replace", suggestedName: "ok.json")
        #expect(FileManager.default.fileExists(atPath: previous.path))

        // Empty name after stripping separators falls back to wallet.json;
        // force a write failure by using a suggested directory that cannot
        // be created as a file child — instead, point FileManager at a
        // non-directory so createDirectory throws.
        let broken = BrokenDirectoryFileManager()
        let failing = ExportStagingFile(fileManager: broken)
        do {
            _ = try failing.write("mnemonic words", suggestedName: "hot.json")
            Issue.record("expected write to throw")
        } catch {
            #expect(failing.url == nil)
        }

        // The previous staging (different instance) is untouched.
        #expect(FileManager.default.fileExists(atPath: previous.path))
        staging.remove()
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    @Test("deinit deletes a leftover mnemonic file")
    func deinitDeletes() throws {
        let url: URL
        do {
            let staging = ExportStagingFile()
            url = try staging.write("secret mnemonic", suggestedName: "hot.json")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("suggested names cannot escape the staging directory")
    func stripsPathSeparators() {
        #expect(ExportStagingFile.safeFileName("winnow-signet-wallet.json")
                    == "winnow-signet-wallet.json")
        #expect(ExportStagingFile.safeFileName("../etc/passwd") == "passwd")
        #expect(ExportStagingFile.safeFileName("/") == "wallet.json")
        #expect(ExportStagingFile.safeFileName("") == "wallet.json")
    }
}

/// FileManager that cannot create directories — used to exercise the
/// write-failure cleanup path without touching a real disk error.
private final class BrokenDirectoryFileManager: FileManager, @unchecked Sendable {
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
