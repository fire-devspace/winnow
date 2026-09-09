import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Whether this platform records a data protection class at all. Apple's
/// CI virtual machines do not: marking a directory `complete` there fails
/// with "couldn't be opened", so every case below would fail at its fixture
/// for a reason that says nothing about the writes. The library's own
/// protected writes succeed on such a platform (the class is ignored, not
/// refused), which every other suite that writes a file proves on the same
/// runner; only the assertion that a class was recorded has nothing to read.
/// Measured once, on a throwaway directory, so the suite is skipped by name
/// rather than failing once per case.
let fileProtectionRecorded: Bool = {
    let url = tempFileURL("probe")
    let directory = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    guard (try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                  ofItemAtPath: directory.path)) != nil,
          let recorded = try? FileManager.default.attributesOfItem(atPath: directory.path)[.protectionKey] as? String
    else { return false }
    return recorded == FileProtectionType.complete.rawValue
}()

/// The data protection class of every file WalletCore writes.
///
/// Each write names `completeUntilFirstUserAuthentication` instead of taking
/// whatever class its directory hands out. The class is the one this wallet
/// already asks for wherever it protects a file: header, filter and relay work
/// continues while the screen is off, so `complete` would stop background sync
/// dead, and a class that comes from the directory is a guarantee only until
/// someone moves the storage.
///
/// Every case below writes into a directory marked `complete` — a class the
/// library asks for nowhere. A new file takes its directory's class unless the
/// write names one, so the marker is what separates a named class from the
/// platform default: without it every file reads back that default and the
/// assertions say nothing about the write. The class is read back the way
/// `KeychainAttributeTests` reads its own attribute, as the recorded string.
@Suite("Persisted file protection", .enabled(if: fileProtectionRecorded))
struct FileProtectionTests {

    // MARK: - Fixtures

    /// The class every write site names.
    static let named = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    /// The class the fixture directory is marked with, which nothing writes.
    static let marker = FileProtectionType.complete.rawValue

    /// A scratch file URL whose directory carries `marker`. Nothing is created
    /// at the URL; the caller's write is the first.
    static func markedFileURL(_ name: String) throws -> URL {
        let url = tempFileURL(name)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                              ofItemAtPath: directory.path)
        // A platform that ignores the marker reports one default class for
        // everything below, which would make every assertion here vacuous.
        try #require(protectionClass(of: directory) == marker)
        return url
    }

    /// The data protection class recorded for `url`, or nil where the platform
    /// records none.
    static func protectionClass(of url: URL) throws -> String? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? String
    }

    // MARK: - Wallet state

    @Test("wallet.json is protected when it is created and when it is saved again")
    func walletState() async throws {
        let url = try Self.markedFileURL("wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let wallet = try makeTestWallet(storageURL: url, keyStore: InMemoryKeyStore())
        #expect(try Self.protectionClass(of: url) == Self.named, "the file wallet creation writes")

        // Deleted so the save writes a new file rather than replacing one that
        // already carries the class: an atomic write keeps the destination's
        // class when it names none, so overwriting would pass either way.
        try FileManager.default.removeItem(at: url)
        try await wallet.recordScanHeight(250)
        #expect(try Self.protectionClass(of: url) == Self.named, "the file a later save writes")
    }

    @Test("an imported wallet's state file is protected")
    func importedWalletState() throws {
        let url = try Self.markedFileURL("wallet.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bundle = ImportBundle(network: "signet", mnemonic: testMnemonic, lastKnownHeight: 500)
        _ = try Wallet.importing(bundle, keyStore: InMemoryKeyStore(), storageURL: url)
        #expect(try Self.protectionClass(of: url) == Self.named)
    }

    // MARK: - Network state

    /// The append path writes into the file the full save created, so it needs
    /// no class of its own — but only as long as that stays true, which is what
    /// the second connect checks.
    @Test("the header file is protected by its full save, and an append keeps it")
    func headerFile() async throws {
        let url = try Self.markedFileURL("headers.dat")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let synthetic = makeSyntheticChain(length: 2, watchHeight: 1)
        let chain = try HeaderChain(params: synthetic.params, storageURL: url)
        _ = try await chain.connect([synthetic.blocks[1].header])
        #expect(try Self.protectionClass(of: url) == Self.named, "the full save")

        _ = try await chain.connect([synthetic.blocks[2].header])
        #expect(try Self.protectionClass(of: url) == Self.named, "after an append")
    }

    @Test("the peers file is protected")
    func peersFile() async throws {
        let url = try Self.markedFileURL("peers.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [], peersFileURL: url)
        await pool.stop()
        #expect(try Self.protectionClass(of: url) == Self.named)
    }

    /// The two files that already named the class. They are here so the suite
    /// is the whole inventory of what WalletCore writes: a write site missing
    /// from this list is a file nothing checks. The one file left out is the
    /// export bundle, which sets its class through `FileManager` under
    /// `#if os(iOS)` and so has none to read back where this suite runs;
    /// `ExportStagingFileTests` covers the rest of its handling.
    @Test("filter progress and the pending relay store are protected")
    func alreadyProtectedFiles() async throws {
        let progressURL = try Self.markedFileURL("filter-progress.json")
        let pendingURL = try Self.markedFileURL("pending-txs.json")
        defer {
            try? FileManager.default.removeItem(at: progressURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pendingURL.deletingLastPathComponent())
        }

        let pool = PeerPool(params: .signet, peerCount: 0, manualPeers: [])
        let chain = try HeaderChain(params: .signet)
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: progressURL)
        try await filters.recordProgressForTest(nextScanHeight: 500)
        #expect(try Self.protectionClass(of: progressURL) == Self.named)

        let broadcaster = try TxBroadcaster(pool: pool, storageURL: pendingURL)
        _ = try await broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true),
                                            feeRateSatPerVByte: 2.5)
        await broadcaster.shutdown()
        #expect(try Self.protectionClass(of: pendingURL) == Self.named)
    }
}
