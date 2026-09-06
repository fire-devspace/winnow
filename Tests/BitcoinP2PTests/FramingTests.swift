import Foundation
import Testing
@testable import BitcoinP2P

/// Message framing/deframing over arbitrary TCP chunk boundaries.
@Suite("Framing")
struct FramingTests {
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
