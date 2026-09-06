import BitcoinCore
import Foundation
import Testing
@testable import BitcoinP2P

/// Filter verification + matching against real BIP158 testnet vectors,
/// exercising CFilterMessage parsing, GCSFilter matching, and the filter
/// header chain rule FilterSync pins.
@Suite("Filter matching (BIP158 vectors)")
struct FilterMatchingTests {
    struct Vector {
        let height: Int
        let blockHash: Data // internal order
        let block: Block
        let previousHeader: Data // internal order
        let filter: Data // NBytes
        let header: Data // internal order
    }

    static func vectors() throws -> [Vector] {
        let json = try JSONSerialization.jsonObject(with: vectorData("bip158-testnet-19.json")) as! [Any]
        return try json.dropFirst().map { entry in
            let row = entry as! [Any]
            guard let blockData = Data(hex: row[2] as! String),
                  let filter = Data(hex: row[5] as! String),
                  let header = Data(hex: row[6] as! String).map({ Data($0.reversed()) }),
                  let blockHash = Data(hex: row[1] as! String).map({ Data($0.reversed()) }),
                  let previousHeader = Data(hex: row[4] as! String).map({ Data($0.reversed()) })
            else { throw VectorError.malformed("hex") }
            return Vector(height: row[0] as! Int,
                          blockHash: blockHash,
                          block: try Block.decode(blockData),
                          previousHeader: previousHeader,
                          filter: filter,
                          header: header)
        }
    }

    @Test("parsed filters match their block's output scripts")
    func matchRealScripts() throws {
        for vector in try Self.vectors() {
            let message = CFilterMessage(blockHash: vector.blockHash, filter: vector.filter)
            let parsed = try message.parsedFilter()
            let filter = try GCSFilter(p: GCSFilter.defaultP, m: GCSFilter.defaultM,
                                       key: Data(vector.blockHash.prefix(16)),
                                       n: parsed.n, encoded: parsed.encoded)
            let scripts = vector.block.transactions
                .flatMap { $0.outputs.map(\.scriptPubKey) }
                .filter { !$0.isEmpty && $0.first != 0x6A }
            // Some vector blocks (e.g. height 1414221) carry only OP_RETURN /
            // empty outputs — the basic filter is empty for those by design.
            guard !scripts.isEmpty else {
                #expect(parsed.n == 0, "height \(vector.height)")
                #expect(!filter.containsAny([Data([0x51])]))
                continue
            }
            #expect(filter.containsAny(scripts), "height \(vector.height)")
            for script in Set(scripts) {
                #expect(filter.contains(script), "height \(vector.height)")
            }
            // A foreign script must not match (BIP158 false-positive rate is tiny).
            #expect(!filter.contains(Data([0x51, 0x20] + repeatElement(0x42, count: 32))))
        }
    }

    @Test("filter headers follow the BIP158 chain rule")
    func headerChainRule() throws {
        for vector in try Self.vectors() {
            // header[h] = SHA256d(SHA256d(filter) || header[h-1]) — the exact
            // check FilterSync performs per cfilter.
            let computed = SHA256d.hash(GCSFilter.filterHash(vector.filter) + vector.previousHeader)
            #expect(computed == vector.header, "height \(vector.height)")
        }
    }

    @Test("cfilter wire round-trip carries the NBytes unchanged")
    func cfilterRoundTrip() throws {
        let vector = try Self.vectors()[0]
        let message = CFilterMessage(blockHash: vector.blockHash, filter: vector.filter)
        let decoded = try PeerMessage.decode(command: "cfilter", payload: message.serialized)
        #expect(decoded == .cfilter(message))
    }
}
