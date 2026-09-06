import Foundation
import P256K
import Testing
@testable import BitcoinCore

/// BIP340 test vectors (test-vectors.csv).
@Suite("BIP340")
struct BIP340Tests {
    struct Vector {
        let index: Int
        let secretKey: Data?
        let publicKey: Data
        let auxRand: Data?
        let message: Data
        let signature: Data
        let expected: Bool
    }

    static func vectors() throws -> [Vector] {
        try vectorString("bip340-test-vectors.csv")
            .components(separatedBy: .newlines)
            .dropFirst() // header
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                let cols = line.components(separatedBy: ",")
                guard cols.count >= 7,
                      let index = Int(cols[0]),
                      let publicKey = Data(hex: cols[2]),
                      let signature = Data(hex: cols[5]),
                      cols[4].count % 2 == 0,
                      let message = cols[4].isEmpty ? Data() : Data(hex: cols[4])
                else { throw VectorError.malformed(line) }
                return Vector(
                    index: index,
                    secretKey: cols[1].isEmpty ? nil : Data(hex: cols[1]),
                    publicKey: publicKey,
                    auxRand: cols[3].isEmpty ? nil : Data(hex: cols[3]),
                    message: message,
                    signature: signature,
                    expected: cols[6] == "TRUE"
                )
            }
    }

    @Test("secret key -> x-only public key")
    func publicKeyDerivation() throws {
        for vector in try Self.vectors() {
            guard let secret = vector.secretKey else { continue }
            let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            #expect(Data(key.xonly.bytes) == vector.publicKey, "index \(vector.index)")
        }
    }

    @Test("deterministic signing with auxiliary randomness")
    func signing() throws {
        for vector in try Self.vectors() {
            guard let secret = vector.secretKey, let auxRand = vector.auxRand else { continue }
            let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            var message = [UInt8](vector.message)
            var aux = [UInt8](auxRand)
            let signature = try key.signature(message: &message, auxiliaryRand: &aux)
            #expect(signature.dataRepresentation == vector.signature, "index \(vector.index)")
        }
    }

    @Test("signature verification matches expected results")
    func verification() throws {
        for vector in try Self.vectors() {
            let key = P256K.Schnorr.XonlyKey(dataRepresentation: vector.publicKey)
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: vector.signature)
            var message = [UInt8](vector.message)
            #expect(key.isValid(signature, for: &message) == vector.expected, "index \(vector.index)")
        }
    }
}
