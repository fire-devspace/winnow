import Foundation
import Testing
@testable import BitcoinP2P

/// Every message payload: encode → decode round-trip, plus framed round-trip.
@Suite("Messages")
struct MessageTests {
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
}
