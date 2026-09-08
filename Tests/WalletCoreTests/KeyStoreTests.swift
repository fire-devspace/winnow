import Foundation
import Testing
import TestSupport
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
        let account = try BIP86.accountKey(from: testMaster(), coinType: 1)
            .serialized(network: .testnet)
        for secret in [WalletSecret.mnemonic(testMnemonic),
                       WalletSecret.masterKey("xprv9s21ZrQH143K3GJpoapnV8SFfukcVBSfeCficPSGfubmSFDxo1kuHnLisriDvSnRRuL2Qrg5ggqHKNVpxR86QEC8w35uxmGoggxtQTPvfUu"),
                       WalletSecret.accountKey(xprv: account, masterFingerprint: 0x73C5_DA0A),
                       // A fingerprint with leading zeros: the encoding is
                       // fixed-width hex, so it must not come back shortened.
                       WalletSecret.accountKey(xprv: account, masterFingerprint: 0x0000_00FF)] {
            #expect(try WalletSecret(serialized: secret.serialized) == secret)
        }
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data("unknown\npayload".utf8))
        }
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data("no-newline".utf8))
        }
        // An account secret is three lines, and its fingerprint line is eight
        // hex digits — not seven, and not a signed integer literal, which
        // `UInt32(_:radix:)` would otherwise accept.
        for text in ["account\n73c5da0a", "account\n73c5da0\n\(account)",
                     "account\n+3c5da0a\n\(account)", "account\n73c5da0a\n\(account)\nextra"] {
            #expect(throws: KeyStoreError.malformedSecret) {
                _ = try WalletSecret(serialized: Data(text.utf8))
            }
        }
    }
}
