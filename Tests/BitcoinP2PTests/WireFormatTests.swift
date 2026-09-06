import Foundation
import Testing
@testable import BitcoinP2P

/// Wire-format primitives: varint/varstring, network addresses, inv vectors.
@Suite("Wire format")
struct WireFormatTests {
    @Test("compactSize boundary round-trips", arguments: [
        UInt64(0), 0xFC, 0xFD, 0xFE, 0xFF, 0x100, 0xFFFF, 0x1_0000,
        0xFFFF_FFFF, 0x1_0000_0000, 0xFFFF_FFFF_FFFF_FFFF,
    ])
    func varIntRoundTrip(value: UInt64) throws {
        var data = Data()
        data.appendCompactSize(value)
        // Canonical encoding sizes per the protocol.
        let expectedSize = switch value {
        case ..<0xFD: 1
        case ...0xFFFF: 3
        case ...0xFFFF_FFFF: 5
        default: 9
        }
        #expect(data.count == expectedSize)
        var reader = ByteReader(data)
        #expect(try reader.readVarInt() == value)
        try reader.requireEnd()
    }

    /// Found by the fuzzer's canonical-round-trip invariant: a wider prefix
    /// than the value needs used to be accepted, so `fd 00 00` parsed as zero
    /// and re-serialized as the one-byte `00` it should have been. Core's
    /// ReadCompactSize refuses all four of these.
    @Test("compactSize refuses a wider prefix than the value needs", arguments: [
        Data([0xFD, 0x00, 0x00]),                                     // 0 in two bytes
        Data([0xFD, 0xFC, 0x00]),                                     // 0xFC in two bytes
        Data([0xFE, 0x00, 0x00, 0x00, 0x00]),                         // 0 in four
        Data([0xFE, 0xFF, 0xFF, 0x00, 0x00]),                         // 0xFFFF in four
        Data([0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), // 0 in eight
        Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]), // 0xFFFFFFFF in eight
    ])
    func varIntRefusesNonMinimal(encoded: Data) throws {
        var reader = ByteReader(encoded)
        #expect(throws: WireError.invalidVarInt) { try reader.readVarInt() }
    }

    /// The smallest value each prefix is allowed to carry still parses.
    @Test("compactSize accepts each width's first legal value", arguments: [
        (Data([0xFD, 0xFD, 0x00]), UInt64(0xFD)),
        (Data([0xFE, 0x00, 0x00, 0x01, 0x00]), UInt64(0x1_0000)),
        (Data([0xFF, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]), UInt64(0x1_0000_0000)),
    ])
    func varIntAcceptsWidthMinimums(encoded: Data, value: UInt64) throws {
        var reader = ByteReader(encoded)
        #expect(try reader.readVarInt() == value)
        try reader.requireEnd()
    }

    @Test("varstring round-trips")
    func varString() throws {
        var data = Data()
        data.appendVarString("/winnow:0.1/")
        var reader = ByteReader(data)
        #expect(try reader.readVarString() == "/winnow:0.1/")
        try reader.requireEnd()
    }

    @Test("truncated reads throw")
    func truncation() {
        var reader = ByteReader(Data([0x01, 0x02]))
        #expect(throws: WireError.self) { _ = try reader.readUInt32() }
        var empty = ByteReader(Data())
        #expect(throws: WireError.self) { _ = try empty.readUInt8() }
    }

    @Test("trailing bytes are detected")
    func trailing() {
        let reader = ByteReader(Data([0x00]))
        #expect(throws: WireError.self) { try reader.requireEnd() }
    }

    @Test("network address without timestamp (version message layout)")
    func peerAddressNoTime() throws {
        let address = PeerAddress(services: PeerConnection.nodeCompactFilters,
                                  ipv4: (192, 168, 1, 1), port: 38333)
        let data = address.serialized(includeTime: false)
        #expect(data.count == 26)
        // IPv4-mapped IPv6 prefix and big-endian port on the wire.
        #expect(data[8 ..< 12] == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])[0 ..< 4])
        #expect(data.suffix(2) == Data([0x95, 0xBD])) // 38333 BE
        var reader = ByteReader(data)
        let decoded = try PeerAddress.decode(from: &reader, includeTime: false)
        #expect(decoded == address)
        #expect(decoded.endpointDescription == "192.168.1.1:38333")
    }

    @Test("network address with timestamp (addr message layout)")
    func peerAddressWithTime() throws {
        let address = PeerAddress(time: 1_700_000_000, services: 1,
                                  ip: Data(repeating: 0xAB, count: 16), port: 8333)
        let data = address.serialized(includeTime: true)
        #expect(data.count == 30)
        var reader = ByteReader(data)
        let decoded = try PeerAddress.decode(from: &reader, includeTime: true)
        #expect(decoded == address)
        try reader.requireEnd()
    }

    @Test("inv payload round-trip incl. witness types")
    func inventory() throws {
        let vectors = [
            InventoryVector(type: .tx, hash: Data(repeating: 0x01, count: 32)),
            InventoryVector(type: .witnessTx, hash: Data(repeating: 0x02, count: 32)),
            InventoryVector(type: .witnessBlock, hash: Data(repeating: 0x03, count: 32)),
        ]
        let payload = InventoryPayload(vectors)
        let decoded = try InventoryPayload.decode(payload.serialized)
        #expect(decoded == payload)
        #expect(InventoryType.witnessTx.baseType == .tx)
        #expect(InventoryType.witnessBlock.baseType == .block)
        #expect(InventoryType.witnessTx.isWitness)
        #expect(!InventoryType.tx.isWitness)
    }

    @Test("witness type flags match BIP144 wire constants")
    func witnessTypeConstants() {
        #expect(InventoryType.witnessTx.rawValue == 0x4000_0001)
        #expect(InventoryType.witnessBlock.rawValue == 0x4000_0002)
    }
}
