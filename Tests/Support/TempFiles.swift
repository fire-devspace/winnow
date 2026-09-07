import Foundation

/// The per-process root for scratch files, `<temporaryDirectory>/winnow-tests-<pid>`.
/// Every scratch directory below is a UUID child of it, so concurrent tests
/// never collide and whatever a test leaves behind is one directory the OS
/// temp cleaner reclaims.
private let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("winnow-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// A scratch directory under the process root, removed when the object is
/// released. swift-testing has no per-suite teardown, so a test that wants
/// its files gone keeps one of these alive for as long as it uses them —
/// Swift may release an object after its last use, so wrap the test body in
/// `withExtendedLifetime(dir) { … }` when the last file access is not itself
/// a use of `dir`.
public final class TempDir: Sendable {
    public let url: URL

    public init() {
        url = tempRoot.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// A file URL inside the directory; nothing is created at it.
    public func fileURL(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A file URL in a fresh UUID directory under the process root. Nothing
/// removes that directory: a test that wants it gone `defer`s removal of
/// `url.deletingLastPathComponent()` (or holds a `TempDir` instead); the
/// rest waits for the OS temp cleaner to reclaim the root.
public func tempFileURL(_ name: String) -> URL {
    let url = tempRoot
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    return url
}
