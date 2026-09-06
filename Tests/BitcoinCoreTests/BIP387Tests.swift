import Foundation
import Testing
@testable import BitcoinCore

/// BIP387 multi_a/sortedmulti_a vectors parsed from bip-0387.mediawiki.
/// (The task brief calls these "BIP388 vectors"; the descriptor fragments live in BIP387.)
@Suite("BIP387 multi_a/sortedmulti_a")
struct BIP387Tests {
    struct Vectors {
        var valid: [(descriptor: String, scripts: [String])] = []
        var invalid: [String] = []
    }

    static func vectors() throws -> Vectors {
        let text = try vectorString("bip-0387.mediawiki")
        var vectors = Vectors()
        var section = 0 // 0 = before, 1 = valid, 2 = invalid
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
        #expect(vectors.valid.map(\.scripts.count) == [1, 1, 1, 1, 3, 3])
        #expect(vectors.invalid.count == 7)
    }

    @Test("valid descriptors produce the expected scriptPubKeys")
    func validDescriptors() throws {
        for (text, scripts) in try Self.vectors().valid {
            let descriptor = try Descriptor(text)
            for (index, expected) in scripts.enumerated() {
                let outputs = try descriptor.derived(index: UInt32(index))
                #expect(outputs.count == 1)
                #expect(outputs[0].scriptPubKey == Data(hex: expected), "\(text) @ \(index)")
                // The address must encode the same witness program.
                let decoded = try SegwitAddress.decode(outputs[0].address, expectedHRP: "bc")
                #expect(decoded.version == 1)
                #expect(Data(decoded.program) == outputs[0].scriptPubKey.suffix(32))
            }
        }
    }

    @Test("invalid descriptors are rejected at parse or derive time")
    func invalidDescriptors() throws {
        for text in try Self.vectors().invalid {
            #expect((try? Descriptor(text).derived(index: 0)) == nil, "accepted: \(text)")
        }
    }

    @Test("multi_a script template matches the BIP387 text")
    func scriptTemplate() throws {
        // <K1> OP_CHECKSIG <K2> OP_CHECKSIGADD <K3> OP_CHECKSIGADD OP_2 OP_NUMEQUAL
        let keys = [Data(repeating: 0x11, count: 32), Data(repeating: 0x22, count: 32), Data(repeating: 0x33, count: 32)]
        let script = try Multisig.script(threshold: 2, xonlyKeys: keys, sorted: false)
        var expected = Data()
        for (i, key) in keys.enumerated() {
            expected.append(0x20)
            expected.append(key)
            expected.append(i == 0 ? 0xAC : 0xBA)
        }
        expected.append(contentsOf: [0x52, 0x9C])
        #expect(script.bytes == expected)

        // sortedmulti_a sorts the x-only keys first.
        let sorted = try Multisig.script(threshold: 2, xonlyKeys: keys.reversed(), sorted: true)
        #expect(sorted.bytes == expected)

        // k > 16 is pushed as a minimally-encoded script number.
        let big = try Multisig.script(threshold: 17, xonlyKeys: (0 ..< 17).map { Data([UInt8($0 + 1)] + Data(repeating: 0, count: 31)) }, sorted: false)
        #expect(big.bytes.suffix(3) == Data([0x01, 0x11, 0x9C]))
    }
}
