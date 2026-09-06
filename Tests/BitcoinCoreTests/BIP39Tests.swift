import Foundation
import Testing
@testable import BitcoinCore

/// BIP39 vectors from trezor/python-mnemonic (passphrase "TREZOR").
@Suite("BIP39")
struct BIP39Tests {
    struct Vector {
        let entropy: Data
        let mnemonic: String
        let seed: Data
        let xprv: String
    }

    static func englishVectors() throws -> [Vector] {
        let json = try JSONSerialization.jsonObject(with: vectorData("bip39-vectors.json")) as! [String: [[String]]]
        return try json["english"]!.map { entry in
            guard let entropy = Data(hex: entry[0]), let seed = Data(hex: entry[2]) else {
                throw VectorError.badHex(entry[0])
            }
            return Vector(entropy: entropy, mnemonic: entry[1], seed: seed, xprv: entry[3])
        }
    }

    @Test("entropy -> mnemonic")
    func entropyToMnemonic() throws {
        for vector in try Self.englishVectors() {
            #expect(try BIP39.mnemonic(entropy: vector.entropy) == vector.mnemonic)
        }
    }

    @Test("mnemonic validation accepts all vectors")
    func validate() throws {
        for vector in try Self.englishVectors() {
            try BIP39.validate(mnemonic: vector.mnemonic)
        }
    }

    @Test("mnemonic -> seed")
    func mnemonicToSeed() throws {
        for vector in try Self.englishVectors() {
            let seed = try BIP39.seed(mnemonic: vector.mnemonic, passphrase: "TREZOR")
            #expect(seed == vector.seed)
        }
    }

    @Test("seed -> BIP32 master xprv")
    func masterXprv() throws {
        for vector in try Self.englishVectors() {
            let master = try HDKey(seed: vector.seed)
            #expect(master.serialized() == vector.xprv)
        }
    }

    @Test("validation rejects bad checksum and unknown words")
    func rejectsInvalid() throws {
        #expect(throws: BIP39Error.invalidChecksum) {
            try BIP39.validate(mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon")
        }
        #expect(throws: BIP39Error.wordNotInWordlist("notaword")) {
            try BIP39.validate(mnemonic: "notaword abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        }
        #expect(throws: BIP39Error.invalidWordCount) {
            try BIP39.validate(mnemonic: "abandon abandon abandon")
        }
    }

    @Test("wordlist has 2048 sorted words")
    func wordlistSanity() {
        #expect(BIP39.wordlist.count == 2048)
        #expect(BIP39.wordlist == BIP39.wordlist.sorted())
        #expect(BIP39.wordlist[0] == "abandon")
        #expect(BIP39.wordlist[2047] == "zoo")
    }
}
