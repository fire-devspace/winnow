import Foundation
import Testing
@testable import BitcoinCore

/// BIP32 test vectors parsed from bip-0032.mediawiki.
@Suite("BIP32")
struct BIP32Tests {
    struct ChainEntry {
        let path: String
        let xpub: String
        let xprv: String
    }

    struct Vector {
        let seed: Data
        let chains: [ChainEntry]
    }

    static func vectors() throws -> [Vector] {
        let text = try vectorString("bip-0032.mediawiki")
        var vectors: [Vector] = []
        var seed: Data?
        var chains: [ChainEntry] = []
        var path: String?
        var xpub: String?
        var xprv: String?

        func flush() {
            if let path, let xpub, let xprv {
                chains.append(ChainEntry(path: path, xpub: xpub, xprv: xprv))
            }
            path = nil
            xpub = nil
            xprv = nil
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("Seed (hex): ") {
                flush()
                if let seed, !chains.isEmpty { vectors.append(Vector(seed: seed, chains: chains)) }
                seed = Data(hex: String(line.dropFirst("Seed (hex): ".count)))
                chains = []
            } else if line.hasPrefix("* Chain ") {
                flush()
                path = String(line.dropFirst("* Chain ".count))
                    .replacingOccurrences(of: "<sub>H</sub>", with: "'")
            } else if line.hasPrefix("** ext pub: ") {
                xpub = String(line.dropFirst("** ext pub: ".count))
            } else if line.hasPrefix("** ext prv: ") {
                xprv = String(line.dropFirst("** ext prv: ".count))
            }
        }
        flush()
        if let seed, !chains.isEmpty { vectors.append(Vector(seed: seed, chains: chains)) }
        return vectors
    }

    static func invalidKeys() throws -> [String] {
        let text = try vectorString("bip-0032.mediawiki")
        guard let range = text.range(of: "===Test vector 5===") else { throw VectorError.malformed("no vector 5") }
        return text[range.upperBound...].components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("* "), let key = line.dropFirst(2).components(separatedBy: " (").first,
                  key.hasPrefix("x") || key.hasPrefix("t") || key.hasPrefix("D")
            else { return nil }
            return key.trimmingCharacters(in: .whitespaces)
        }
    }

    @Test("4 vectors parsed")
    func vectorCount() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 4)
        #expect(vectors.allSatisfy { !$0.chains.isEmpty })
    }

    @Test("xprv/xpub serialization at every path")
    func serialization() throws {
        for vector in try Self.vectors() {
            let master = try HDKey(seed: vector.seed)
            for chain in vector.chains {
                let key = try master.derived(path: chain.path)
                #expect(key.serialized() == chain.xprv, "\(chain.path)")
                #expect(key.neutered.serialized() == chain.xpub, "\(chain.path)")
                // Round-trip: parsing the xprv reproduces the same key material.
                let parsed = try HDKey.deserialize(chain.xprv)
                #expect(parsed == key, "\(chain.path)")
                let parsedPub = try HDKey.deserialize(chain.xpub)
                #expect(parsedPub.chainCode == key.chainCode, "\(chain.path)")
                #expect(parsedPub.publicKey == key.publicKey, "\(chain.path)")
            }
        }
    }

    @Test("public derivation matches private derivation for non-hardened steps")
    func publicDerivation() throws {
        for vector in try Self.vectors() {
            let master = try HDKey(seed: vector.seed)
            for chain in vector.chains {
                guard let split = chain.path.split(separator: "/").last,
                      !split.hasSuffix("'"), chain.path != "m"
                else { continue }
                let parentPath = String(chain.path.dropLast(split.count + 1))
                let index = UInt32(split)!
                let parentPub = try master.derived(path: parentPath).neutered
                let child = try parentPub.child(at: index)
                #expect(child.serialized() == chain.xpub, "\(chain.path)")
            }
        }
    }

    @Test("hardened derivation from public key throws")
    func hardenedFromPublic() throws {
        let master = try HDKey(seed: Data(hex: "000102030405060708090a0b0c0d0e0f")!)
        #expect(throws: BIP32Error.hardenedDerivationFromPublicKey) {
            try master.neutered.child(at: HDKey.hardenedOffset)
        }
    }

    @Test("vector 5 invalid extended keys are rejected")
    func invalidKeysRejected() throws {
        let keys = try Self.invalidKeys()
        #expect(keys.count == 16)
        for key in keys {
            #expect(throws: (any Error).self, "\(key)") {
                try HDKey.deserialize(key)
            }
        }
    }
}
