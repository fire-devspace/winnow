import Foundation
import Testing
import TestSupport

/// The BIP340 vectors (test-vectors.csv) are exercised against the repo's own
/// Schnorr paths by `SighashBIP341Tests.witnessSignatures` and
/// `MuSig2Tests.sigAgg`; this only keeps the shipped resource from rotting.
@Suite("BIP340")
struct BIP340Tests {
    @Test("the shipped test-vectors.csv still parses with every row present")
    func vectorFileParses() throws {
        let rows = try Vectors.string("bip340-test-vectors.csv", in: .module)
            .components(separatedBy: .newlines)
            .dropFirst() // header
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(rows.compactMap { Int($0.components(separatedBy: ",")[0]) } == Array(0 ... 18))
    }
}
