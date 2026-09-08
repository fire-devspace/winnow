@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

final class VaultBackupTests: XCTestCase {
    func testBackupPreservesAccountsAndRejectsChangedOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "vaults.json")
        let (vault, _) = try TestVaults.muSig2Vault()
        let descriptor = vault.descriptor.serialized()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000)
        let record = VaultRecord(id: String(descriptor.split(separator: "#").last!),
                                 name: "Phone and desktop", descriptor: descriptor,
                                 createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: [coin])
        let store = VaultStore()
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        var backup = ImportBundle(network: "signet", lastKnownHeight: coin.height)
        backup.vaults = try await store.backupRecords()
        let decoded = try ImportBundle.decode(json: backup.serialized())
        XCTAssertEqual(decoded.vaults, [record])
        XCTAssertNil(decoded.mnemonic)
        let restarted = VaultStore()
        let opened = await restarted.configure(storageURL: url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let loaded = await restarted.all
        XCTAssertEqual(loaded, decoded.vaults)

        var changed = record
        changed.allUtxos[0].scriptPubKey = Data([0x51])
        do {
            try await restarted.restore([changed])
            XCTFail("backup with a foreign coin was accepted")
        } catch {}
        let unchanged = await restarted.all
        XCTAssertEqual(unchanged, [record])
        XCTAssertEqual(try JSONDecoder().decode([VaultRecord].self, from: Data(contentsOf: url)), [record])
    }

    func testBackupWaitsForPendingAccountPayments() async throws {
        let (vault, _) = try TestVaults.muSig2Vault()
        let text = vault.descriptor.serialized()
        var coin = try TestVaults.funding(vault: vault, amount: 80_000)
        coin.height = 0
        let record = VaultRecord(id: String(text.split(separator: "#").last!), name: "Pending",
                                 descriptor: text, createdAtHeight: 0,
                                 nextReceiveIndex: 1, allUtxos: [coin])
        let store = VaultStore()
        await store.configure(storageURL: nil, network: .signet)
        try await store.restore([record])
        do {
            _ = try await store.backupRecords()
            XCTFail("an unconfirmed account snapshot was exported")
        } catch {}
    }
}
