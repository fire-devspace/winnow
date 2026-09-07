import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The wire: varints and varstrings, network addresses and inv vectors, every
/// message payload, and the framing that carries them over TCP.
///
/// Combined from `Wire format`, `Messages` and `Framing`, none of which
/// carried a suite trait. Each section keeps its source suite's tests, their
/// display names, their order and their fixtures.
@Suite("Wire")
struct WireTests {

    // MARK: - Wire format
    //
    // Wire-format primitives: varint/varstring, network addresses, inv
    // vectors.

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

    // MARK: - Messages
    //
    // Every message payload: encode → decode round-trip, plus framed
    // round-trip.

    static let hash = Data(repeating: 0xAB, count: 32)

    static func allMessages() -> [PeerMessage] {
        let version = VersionMessage(
            version: 70_016, services: PeerConnection.nodeCompactFilters,
            timestamp: 1_700_000_000,
            receiver: PeerAddress(services: 0, ipv4: (127, 0, 0, 1), port: 38333),
            sender: PeerAddress(services: 0, ipv4: (10, 0, 0, 2), port: 8333),
            nonce: 0xDEAD_BEEF, userAgent: "/winnow:0.1/", startHeight: 123, relay: false)
        let inv = InventoryPayload([
            InventoryVector(type: .witnessTx, hash: hash),
            InventoryVector(type: .witnessBlock, hash: Data(repeating: 0xCD, count: 32)),
        ])
        let tx = makeFakeSegwitTx()
        let header = BlockHeader(version: 1, previousHash: hash, merkleRoot: hash,
                                 time: 1_600_000_000, bits: 0x1E03_77AE, nonce: 42)
        return [
            .version(version),
            .verack,
            .ping(0x0102_0304_0506_0708),
            .pong(0xDEAD_BEEF),
            .sendheaders,
            .feefilter(2_500), // BIP133 sat/kvB
            .inv(inv),
            .getdata(inv),
            .notfound(inv),
            .tx(tx),
            .block(Block(header: header, transactions: [tx])),
            .getheaders(GetHeadersMessage(version: 70_016, locatorHashes: [hash, hash])),
            .getheaders(GetHeadersMessage(version: 70_016, locatorHashes: [], stopHash: hash)),
            .headers([header, header]),
            .headers([]),
            .getcfilters(GetCFiltersRequest(startHeight: 100, stopHash: hash)),
            .cfilter(CFilterMessage(blockHash: hash, filter: Data([0x03, 0xAA, 0xBB, 0xCC]))),
            .getcfheaders(GetCFiltersRequest(startHeight: 0, stopHash: hash)),
            .cfheaders(CFHeadersMessage(stopHash: hash, previousFilterHeader: hash,
                                        filterHashes: [hash, hash])),
            .getcfcheckpt(GetCFCheckptRequest(stopHash: hash)),
            .cfcheckpt(CFCheckptMessage(stopHash: hash, filterHeaders: [hash])),
            .unknown(command: "sendcmpct", payload: Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])),
        ]
    }

    @Test("payload encode → decode round-trips", arguments: allMessages())
    func roundTrip(message: PeerMessage) throws {
        let decoded = try PeerMessage.decode(command: message.command, payload: message.payload)
        #expect(decoded == message, "\(message.command)")
    }

    @Test("framed round-trip through the deframer", arguments: allMessages())
    func framedRoundTrip(message: PeerMessage) throws {
        let framed = MessageFramer.frame(command: message.command, payload: message.payload,
                                         magic: NetworkParams.signet.magic)
        var framer = MessageFramer(magic: NetworkParams.signet.magic)
        framer.append(framed)
        guard let framedMessage = try framer.nextMessage() else {
            Issue.record("no message deframed")
            return
        }
        #expect(framedMessage.command == message.command)
        let decoded = try PeerMessage.decode(command: framedMessage.command, payload: framedMessage.payload)
        #expect(decoded == message, "\(message.command)")
        #expect(try framer.nextMessage() == nil)
    }

    @Test("feefilter payload is int64 LE sat/kvB (BIP133)")
    func feefilterLayout() throws {
        let payload = PeerMessage.feefilter(1_000).payload
        #expect(payload == Data([0xE8, 0x03, 0, 0, 0, 0, 0, 0]))
        guard case let .feefilter(rate) = try PeerMessage.decode(command: "feefilter", payload: payload) else {
            Issue.record("wrong decode")
            return
        }
        #expect(rate == 1_000)
    }

    @Test("version message decodes without the optional relay flag")
    func versionWithoutRelay() throws {
        let version = VersionMessage(version: 70_001, services: 0, timestamp: 0,
                                     receiver: .unspecified, sender: .unspecified,
                                     nonce: 1, userAgent: "/old/", startHeight: 0, relay: true)
        var payload = version.serialized
        payload.removeLast() // drop relay byte
        let decoded = try VersionMessage.decode(payload)
        #expect(decoded.relay == true) // absent means "relay" pre-BIP37 semantics
        #expect(decoded.userAgent == "/old/")
    }

    @Test("getcfilters/getcfheaders/getcfcheckpt exact BIP157 layout")
    func bip157Layout() {
        let request = GetCFiltersRequest(filterType: 0, startHeight: 0x0102_0304, stopHash: Self.hash)
        #expect(request.serialized == Data([0x00, 0x04, 0x03, 0x02, 0x01]) + Self.hash)
        let checkpt = GetCFCheckptRequest(filterType: 0, stopHash: Self.hash)
        #expect(checkpt.serialized == Data([0x00]) + Self.hash)
        let cfilter = CFilterMessage(blockHash: Self.hash, filter: Data([0x01, 0x02]))
        #expect(cfilter.serialized == Data([0x00]) + Self.hash + Data([0x02, 0x01, 0x02]))
    }

    @Test("headers message carries a zero txn_count after each header")
    func headersTxnCount() throws {
        let header = BlockHeader(version: 1, previousHash: Self.hash, merkleRoot: Self.hash,
                                 time: 0, bits: 0, nonce: 0)
        let payload = PeerMessage.headers([header]).payload
        #expect(payload.count == 1 + 80 + 1)
        #expect(payload.last == 0)
    }

    @Test("oversized headers count is rejected")
    func headersCountGuard() {
        var payload = Data()
        payload.appendCompactSize(2_001)
        #expect(throws: WireError.self) { _ = try PeerMessage.decode(command: "headers", payload: payload) }
    }

    @Test("a filter element count above UInt32.max is rejected, not force-cast")
    func parsedFilterCountGuard() {
        // Leading GCS count of 2^40 (>UInt32.max) must throw rather than trap
        // in UInt32(n). The tiny payload keeps this cheap.
        var filter = Data()
        filter.appendCompactSize(1 << 40)
        filter.append(contentsOf: [0xAA, 0xBB])
        let message = CFilterMessage(blockHash: Self.hash, filter: filter)
        #expect(throws: WireError.self) { _ = try message.parsedFilter() }

        // A normal small count still parses.
        var ok = Data()
        ok.appendCompactSize(3)
        ok.append(contentsOf: [0xAA, 0xBB, 0xCC])
        #expect(throws: Never.self) { _ = try CFilterMessage(blockHash: Self.hash, filter: ok).parsedFilter() }
    }

    // MARK: - Framing
    //
    // Message framing/deframing over arbitrary TCP chunk boundaries.

    let magic = NetworkParams.signet.magic

    func framedPing(nonce: UInt64 = 0x0102_0304_0506_0708) -> Data {
        MessageFramer.frame(command: "ping", payload: PeerMessage.ping(nonce).payload, magic: magic)
    }

    @Test("header layout: magic, zero-padded command, LE length, checksum")
    func headerLayout() throws {
        let frame = framedPing()
        #expect(frame.count == 24 + 8)
        #expect(frame.prefix(4) == magic)
        #expect(frame[4 ..< 16] == Data("ping".utf8) + Data(repeating: 0, count: 8))
        #expect(frame[16 ..< 20] == Data([0x08, 0, 0, 0])) // payload length, LE
        #expect(frame[20 ..< 24] == SHA256d.hash(PeerMessage.ping(0x0102_0304_0506_0708).payload).prefix(4))
    }

    @Test("message survives 1-byte-chunk delivery")
    func splitChunks() throws {
        let frame = framedPing()
        var framer = MessageFramer(magic: magic)
        var result: (command: String, payload: Data)?
        for byte in frame {
            framer.append(Data([byte]))
            result = try framer.nextMessage()
        }
        let (command, payload) = try #require(result)
        #expect(command == "ping")
        #expect(payload == PeerMessage.ping(0x0102_0304_0506_0708).payload)
    }

    @Test("two coalesced messages deframe in order")
    func coalesced() throws {
        var framer = MessageFramer(magic: magic)
        framer.append(framedPing(nonce: 1) + framedPing(nonce: 2))
        guard let first = try framer.nextMessage(), let second = try framer.nextMessage() else {
            Issue.record("expected two messages")
            return
        }
        #expect(try PeerMessage.decode(command: first.command, payload: first.payload) == .ping(1))
        #expect(try PeerMessage.decode(command: second.command, payload: second.payload) == .ping(2))
        #expect(framer.bufferedCount == 0)
    }

    @Test("wrong magic is rejected")
    func badMagic() {
        var frame = framedPing()
        frame[0] ^= 0xFF
        var framer = MessageFramer(magic: magic)
        framer.append(frame)
        #expect(throws: FramingError.badMagic) { _ = try framer.nextMessage() }
    }

    @Test("corrupted payload fails the checksum")
    func badChecksum() {
        var frame = framedPing()
        frame[frame.count - 1] ^= 0xFF // flip a payload bit
        var framer = MessageFramer(magic: magic)
        framer.append(frame)
        #expect(throws: FramingError.checksumMismatch("ping")) { _ = try framer.nextMessage() }
    }

    @Test("oversized length field is rejected before buffering")
    func oversized() {
        var header = Data()
        header.append(magic)
        header.append(contentsOf: Data("block".utf8) + Data(repeating: 0, count: 7))
        header.appendUInt32(UInt32(MessageFramer.maxPayloadSize) + 1)
        header.append(Data(repeating: 0, count: 4))
        var framer = MessageFramer(magic: magic)
        framer.append(header)
        #expect(throws: FramingError.payloadTooLarge(UInt32(MessageFramer.maxPayloadSize) + 1)) {
            _ = try framer.nextMessage()
        }
    }

    @Test("partial frame yields nil, then completes")
    func partialThenComplete() throws {
        let frame = framedPing()
        var framer = MessageFramer(magic: magic)
        framer.append(frame.prefix(10))
        #expect(try framer.nextMessage() == nil)
        framer.append(frame[10 ..< 20])
        #expect(try framer.nextMessage() == nil) // header still incomplete
        framer.append(frame[20 ..< 24])
        #expect(try framer.nextMessage() == nil) // header complete, payload missing
        framer.append(frame.suffix(8))
        #expect(try framer.nextMessage() != nil)
    }
}
