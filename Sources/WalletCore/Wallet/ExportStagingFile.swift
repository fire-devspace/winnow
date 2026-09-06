import Foundation

/// Stages a wallet-bundle JSON in a unique, backup-excluded temp file the
/// share sheet can hand off. The previous file is deleted on every write,
/// on `remove()`, and on deinit — toggling the seed or dismissing the
/// export sheet must not leave a mnemonic sitting in `temporaryDirectory`.
public final class ExportStagingFile: @unchecked Sendable {
    private let fileManager: FileManager
    public private(set) var url: URL?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    deinit { remove() }

    /// Writes `contents` under a UUID-named directory so two exports never
    /// share a path. `suggestedName` is the share-sheet filename (path
    /// separators stripped).
    @discardableResult
    public func write(_ contents: String, suggestedName: String) throws -> URL {
        remove()
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("winnow-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = Self.safeFileName(suggestedName)
            let fileURL = dir.appendingPathComponent(name)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            try Self.protect(fileURL, fileManager: fileManager)
            try Self.protect(dir, fileManager: fileManager)
            url = fileURL
            return fileURL
        } catch {
            try? fileManager.removeItem(at: dir)
            url = nil
            throw error
        }
    }

    public func remove() {
        guard let url else { return }
        try? fileManager.removeItem(at: url.deletingLastPathComponent())
        self.url = nil
    }

    static func safeFileName(_ suggested: String) -> String {
        let trimmed = suggested.split(separator: "/").last.map(String.init) ?? ""
        return trimmed.isEmpty ? "wallet.json" : trimmed
    }

    private static func protect(_ url: URL, fileManager: FileManager) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
