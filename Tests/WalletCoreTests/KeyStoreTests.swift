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
        for text in ["account/1\n73c5da0a", "account/1\n73c5da0\n\(account)",
                     "account/1\n+3c5da0a\n\(account)", "account/1\n73c5da0a\n\(account)\nextra"] {
            #expect(throws: KeyStoreError.malformedSecret) {
                _ = try WalletSecret(serialized: Data(text.utf8))
            }
        }
    }

    /// One spelling of a fingerprint, decided by the writer. `serialized`
    /// writes lowercase, and every wallet ID and descriptor origin beside it is
    /// lowercase, so the same key must not have a second encoding that also
    /// reads back: two stored blobs that compare unequal for a key that is the
    /// same key is a difference nothing downstream can interpret.
    @Test("an uppercase fingerprint is not a second spelling of the same secret")
    func accountFingerprintIsLowercase() throws {
        let account = try BIP86.accountKey(from: testMaster(), coinType: 1)
            .serialized(network: .testnet)
        let secret = WalletSecret.accountKey(xprv: account, masterFingerprint: 0x73C5_DA0A)
        let written = String(decoding: secret.serialized, as: UTF8.self)
        #expect(written.contains("\n73c5da0a\n"))
        let shouted = written.replacingOccurrences(of: "73c5da0a", with: "73C5DA0A")
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data(shouted.utf8))
        }
    }

    /// The account encoding carries its version in the header, so a build that
    /// meets a shape it has no rules for says so by name instead of reading the
    /// lines beneath on the assumption they mean what they used to. Being told
    /// the key needs a newer build is a different instruction from being told
    /// it is damaged, and only one of them is worth acting on.
    @Test("an account secret from an unknown version is refused by name")
    func accountVersionRefusedByName() throws {
        let account = try BIP86.accountKey(from: testMaster(), coinType: 1)
            .serialized(network: .testnet)
        for header in ["account/2", "account/1a", "account/"] {
            #expect(throws: KeyStoreError.unsupportedSecretVersion(header)) {
                _ = try WalletSecret(serialized: Data("\(header)\n73c5da0a\n\(account)".utf8))
            }
        }
        // The untagged header the fork wrote before the version existed is not
        // a version at all, so it stays plain damage.
        #expect(throws: KeyStoreError.malformedSecret) {
            _ = try WalletSecret(serialized: Data("account\n73c5da0a\n\(account)".utf8))
        }
    }

    /// Upstream's two encodings are byte-for-byte what they always were: a
    /// device holding one was written by a shipped build, and this fork's new
    /// case must not have moved a byte of it.
    @Test("the root encodings are unchanged")
    func rootEncodingsUnchanged() throws {
        let xprv = "xprv9s21ZrQH143K3GJpoapnV8SFfukcVBSfeCficPSGfubmSFDxo1kuHnLisriDvSnRRuL2Qrg5ggqHKNVpxR86QEC8w35uxmGoggxtQTPvfUu"
        #expect(WalletSecret.mnemonic(testMnemonic).serialized
            == Data("mnemonic\n\(testMnemonic)".utf8))
        #expect(WalletSecret.masterKey(xprv).serialized == Data("xprv\n\(xprv)".utf8))
    }
}
