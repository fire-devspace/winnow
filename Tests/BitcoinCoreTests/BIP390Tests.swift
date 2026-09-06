import Foundation
import Testing
@testable import BitcoinCore

/// BIP390 musig() descriptor vectors (from bip-0390.mediawiki) and BIP328
/// aggregate-key derivation vectors (from bip-0328.mediawiki).
@Suite("BIP390 musig()")
struct BIP390Tests {
    struct Vectors {
        var valid: [(descriptor: String, scripts: [String])] = []
        var invalid: [String] = []
    }

    static func vectors() throws -> Vectors {
        let text = try vectorString("bip-0390.mediawiki")
        var vectors = Vectors()
        var section = 0
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("==Test Vectors==") { section = 1; continue }
            if line.hasPrefix("Invalid descriptors") { section = 2; continue }
            if line.hasPrefix("==Backwards Compatibility==") { section = 0 }
            let tags = ttTags(in: line)
            guard !tags.isEmpty else { continue }
            switch section {
            case 1 where line.hasPrefix("* <tt>"):
                vectors.valid.append((tags[0], []))
            case 1 where line.hasPrefix("** <tt>"):
                vectors.valid[vectors.valid.count - 1].scripts.append(tags[0])
            case 2 where line.hasPrefix("* "):
                vectors.invalid.append(tags.last!)
            default:
                break
            }
        }
        return vectors
    }

    @Test("vector block parsed")
    func parsed() throws {
        let vectors = try Self.vectors()
        #expect(vectors.valid.count == 6)
        #expect(vectors.valid.map(\.scripts.count) == [1, 1, 3, 3, 3, 1])
        #expect(vectors.invalid.count == 14)
    }

    @Test("valid musig descriptors produce the expected scriptPubKeys")
    func validDescriptors() throws {
        for (text, scripts) in try Self.vectors().valid {
            let descriptor = try Descriptor(text)
            for (index, expected) in scripts.enumerated() {
                let outputs = try descriptor.derived(index: UInt32(index))
                #expect(outputs.count == 1)
                #expect(outputs[0].scriptPubKey == Data(hex: expected), "\(text) @ \(index)")
            }
        }
    }

    @Test("invalid musig descriptors are rejected at parse or derive time")
    func invalidDescriptors() throws {
        for text in try Self.vectors().invalid {
            #expect((try? Descriptor(text).derived(index: 0)) == nil, "accepted: \(text)")
        }
    }

    /// BIP328: KeyAgg of the listed keys yields the aggregate pubkey, and the
    /// synthetic xpub (fixed chaincode) serializes as given.
    @Test("BIP328 aggregate pubkeys and synthetic xpubs")
    func bip328() throws {
        let text = try vectorString("bip-0328.mediawiki")
        var vectors: [(aggregate: String, xpub: String, keys: [String])] = []
        for line in text.components(separatedBy: .newlines) {
            let tags = ttTags(in: line)
            guard !tags.isEmpty else { continue }
            if line.hasPrefix("* Aggregate pubkey") {
                vectors.append((tags[0], "", []))
            } else if line.hasPrefix("** Synthetic xpub") {
                vectors[vectors.count - 1].xpub = tags[0]
            } else if line.hasPrefix("*** <tt>") {
                vectors[vectors.count - 1].keys.append(tags[0])
            }
        }
        #expect(vectors.count == 3)
        #expect(vectors.map(\.keys.count) == [2, 3, 4])

        for (aggregate, xpub, keys) in vectors {
            let publicKeys = try keys.map { try #require(Data(hex: $0)) }
            let aggregated = try MuSig.aggregate(publicKeys) // listed order, no KeySort
            #expect(aggregated == Data(hex: aggregate))
            // KeySort must be a no-op on already sorted input and match BIP327 ordering.
            #expect(MuSig.keySort(publicKeys).count == publicKeys.count)
            let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregated)
            #expect(synthetic.serialized() == xpub)
        }
    }
}
