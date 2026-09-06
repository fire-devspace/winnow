import Foundation
import Testing
@testable import WalletCore

@Suite("KeyStore")
struct KeyStoreTests {
    @Test("InMemoryKeyStore store/load/delete round trip")
    func roundTrip() throws {
        let store = InMemoryKeyStore()
        #expect(throws: KeyStoreError.notFound(walletID: "w1")) { _ = try store.load(walletID: "w1") }

        try store.store(.mnemonic(testMnemonic), for: "w1")
        #expect(try store.load(walletID: "w1") == .mnemonic(testMnemonic))

        #expect(throws: KeyStoreError.alreadyExists(walletID: "w1")) {
            _ = try store.store(.mnemonic(testMnemonic), for: "w1")
        }

        try store.delete(walletID: "w1")
        #expect(throws: KeyStoreError.notFound(walletID: "w1")) { _ = try store.load(walletID: "w1") }
        try store.delete(walletID: "w1") // deleting an absent ID is a no-op
    }

    @Test("WalletSecret tagged serialization round trip")
    func secretSerialization() throws {
        for secret in [WalletSecret.mnemonic(testMnemonic),
                       WalletSecret.masterKey("xprv9s21ZrQH143K3GJpoapnV8SFfukcVBSfeCficPSGfubmSFDxo1kuHnLisriDvSnRRuL2Qrg5ggqHKNVpxR86QEC8w35uxmGoggxtQTPvfUu")] {
            #expect(try WalletSecret(serialized: secret.serialized) == secret)
        }
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data("unknown\npayload".utf8))
        }
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data("no-newline".utf8))
        }
    }
}
