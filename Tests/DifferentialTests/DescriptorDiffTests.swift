import BitcoinCore
import Foundation
import Testing

/// `deriveaddresses` (Bitcoin Core 31, custom signet) vs our
/// `Descriptor.derived(index:network:)` — the descriptor engine is the wallet's
/// address source of truth, so any drift here means missed payments.
@Suite("deriveaddresses differential", .enabled(if: diffEnabled))
struct DescriptorDiffTests {
    private static let window: ClosedRange<Int> = 0 ... 4

    /// Compares our derivations against Core's over `window`; returns Core's
    /// addresses (nil when Core rejects the descriptor — caller decides).
    private func coreAddresses(_ descriptor: Descriptor) throws -> [String]? {
        do {
            return try BitcoinCLI.runJSON([
                "deriveaddresses", descriptor.serialized(),
                "[\(Self.window.lowerBound),\(Self.window.upperBound)]",
            ]) as? [String]
        } catch let error as BitcoinCLI.CLIError {
            print("deriveaddresses rejected \(descriptor.serialized()): \(error.output)")
            return nil
        }
    }

    private func expectAgreement(_ descriptor: Descriptor, file: String) throws {
        let core = try #require(try coreAddresses(descriptor), "\(file): Core rejected the descriptor")
        #expect(core.count == Self.window.count)
        for (offset, expected) in core.enumerated() {
            let ours = try descriptor.derived(index: UInt32(Self.window.lowerBound + offset),
                                              network: .testnet)
            #expect(ours.count == 1, "\(file): expected a single (non-multipath) output")
            #expect(ours[0].address == expected,
                    "\(file) index \(Self.window.lowerBound + offset)")
        }
    }

    @Test("BIP86 single-sig tr() descriptor")
    func singleSig() throws {
        let master = try testMaster()
        let account = try BIP86.accountKey(from: master, coinType: 1)
        let origin = String(format: "%08x", master.fingerprint)
        let descriptor = try Descriptor(
            "tr([\(origin)/86'/1'/0']\(account.neutered.serialized(network: .testnet))/0/*)")
        try expectAgreement(descriptor, file: "tr() BIP86")
    }

    @Test("2-of-3 sortedmulti_a leaf descriptor")
    func sortedMultiA() throws {
        // Three participant account keys from three throwaway seeds, plus a
        // fourth as the tr() internal key — every key ranged at the same step.
        var xpubs: [String] = []
        for index: UInt8 in 0 ..< 4 {
            let entropy = Data([index + 1] + Data(repeating: 0, count: 15))
            let master = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: entropy)))
            let account = try BIP86.accountKey(from: master, coinType: 1)
            xpubs.append(account.neutered.serialized(network: .testnet))
        }
        let descriptor = try Descriptor(
            "tr(\(xpubs[3])/0/*,sortedmulti_a(2,\(xpubs[0])/0/*,\(xpubs[1])/0/*,\(xpubs[2])/0/*))")
        try expectAgreement(descriptor, file: "sortedmulti_a 2-of-3")
    }

    @Test("BIP390 musig() descriptor")
    func musig() throws {
        var xpubs: [String] = []
        for index: UInt8 in 0 ..< 2 {
            let entropy = Data([index + 11] + Data(repeating: 0, count: 15))
            let master = try HDKey(seed: BIP39.seed(mnemonic: BIP39.mnemonic(entropy: entropy)))
            let account = try BIP86.accountKey(from: master, coinType: 1)
            xpubs.append(account.neutered.serialized(network: .testnet))
        }
        let descriptor = try Descriptor("tr(musig(\(xpubs[0]),\(xpubs[1]))/0/*)")
        guard let core = try coreAddresses(descriptor) else {
            print("SKIPPED musig() deriveaddresses: this Core build rejects BIP390 descriptors")
            return
        }
        #expect(core.count == Self.window.count)
        for (offset, expected) in core.enumerated() {
            let ours = try descriptor.derived(index: UInt32(Self.window.lowerBound + offset),
                                              network: .testnet)
            #expect(ours[0].address == expected, "musig() index \(Self.window.lowerBound + offset)")
        }
    }
}
