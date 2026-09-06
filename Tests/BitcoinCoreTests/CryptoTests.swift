import Foundation
import Testing
@testable import BitcoinCore

@Suite("Crypto primitives")
struct CryptoTests {
    @Test("RIPEMD-160 known vectors")
    func ripemd160() {
        #expect(RIPEMD160.hash(Data()).hex == "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        #expect(RIPEMD160.hash(Data("abc".utf8)).hex == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        #expect(RIPEMD160.hash(Data("message digest".utf8)).hex == "5d0689ef49d2fae572b881b123a85ffa21595f36")
    }

    @Test("Base58Check round-trip preserves leading zeros")
    func base58() throws {
        let payload = Data([0, 0, 1, 2, 3, 254, 255])
        let encoded = Base58Check.encode(payload)
        #expect(encoded.hasPrefix("11"))
        #expect(try Base58Check.decode(encoded) == payload)
        #expect(throws: Base58Error.invalidChecksum) {
            _ = try Base58Check.decode(String(encoded.dropLast(1)) + (encoded.hasSuffix("1") ? "2" : "1"))
        }
    }
}
