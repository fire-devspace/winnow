import Foundation

/// Minimal 256-bit unsigned integer for PoW target and chainwork math.
/// Four little-endian UInt64 limbs. Only the operations header sync needs:
/// comparison, wrapping add/subtract, shifts, and long division.
struct UInt256: Equatable, Comparable, Sendable {
    private(set) var limbs: [UInt64] // 4 limbs, least significant first

    init() { limbs = [0, 0, 0, 0] }

    init(_ value: UInt64) { limbs = [value, 0, 0, 0] }

    private init(limbs: [UInt64]) { self.limbs = limbs }

    /// From a 32-byte big-endian number.
    init(bigEndian bytes: Data) {
        precondition(bytes.count == 32)
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0 ..< 4 {
            var limb: UInt64 = 0
            let base = 31 - i * 8 // most significant byte of this limb
            for j in 0 ..< 8 { limb |= UInt64(bytes[base - j]) << (8 * j) }
            limbs[i] = limb
        }
        self.limbs = limbs
    }

    /// From a 32-byte little-endian number (internal hash byte order).
    init(littleEndian bytes: Data) {
        precondition(bytes.count == 32)
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0 ..< 4 {
            var limb: UInt64 = 0
            for j in 0 ..< 8 { limb |= UInt64(bytes[i * 8 + j]) << (8 * j) }
            limbs[i] = limb
        }
        self.limbs = limbs
    }

    /// Big-endian 32-byte representation (display order).
    var bigEndianData: Data {
        var data = Data()
        for i in 0 ..< 4 {
            let limb = limbs[3 - i]
            for j in 0 ..< 8 { data.append(UInt8(truncatingIfNeeded: limb >> (8 * (7 - j)))) }
        }
        return data
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    static let max = UInt256(limbs: [.max, .max, .max, .max])

    static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in stride(from: 3, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    /// Wrapping (mod 2^256) addition — chainwork never overflows in practice.
    static func + (lhs: UInt256, rhs: UInt256) -> UInt256 {
        var result = UInt256()
        var carry = false
        for i in 0 ..< 4 {
            let (sum1, overflow1) = lhs.limbs[i].addingReportingOverflow(rhs.limbs[i])
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry ? 1 : 0)
            result.limbs[i] = sum2
            carry = overflow1 || overflow2
        }
        return result
    }

    /// Wrapping subtraction; only called when lhs >= rhs.
    static func - (lhs: UInt256, rhs: UInt256) -> UInt256 {
        var result = UInt256()
        var borrow = false
        for i in 0 ..< 4 {
            let (diff1, overflow1) = lhs.limbs[i].subtractingReportingOverflow(rhs.limbs[i])
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow ? 1 : 0)
            result.limbs[i] = diff2
            borrow = overflow1 || overflow2
        }
        return result
    }

    func shiftedLeft(_ bits: Int) -> UInt256 {
        guard bits > 0 else { return self }
        var result = UInt256()
        let limbShift = bits / 64
        let bitShift = bits % 64
        for i in 0 ..< 4 {
            let source = i - limbShift
            guard source >= 0 else { continue }
            result.limbs[i] |= limbs[source] << bitShift
            if bitShift > 0, source > 0 {
                result.limbs[i] |= limbs[source - 1] >> (64 - bitShift)
            }
        }
        return result
    }

    /// Bitwise long division.
    func quotientAndRemainder(dividingBy divisor: UInt256) -> (quotient: UInt256, remainder: UInt256) {
        precondition(!divisor.isZero, "division by zero")
        var quotient = UInt256()
        var remainder = UInt256()
        for bit in stride(from: 255, through: 0, by: -1) {
            remainder = remainder.shiftedLeft(1)
            if (limbs[bit / 64] >> (bit % 64)) & 1 == 1 { remainder.limbs[0] |= 1 }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient.limbs[bit / 64] |= 1 << (bit % 64)
            }
        }
        return (quotient, remainder)
    }

    /// Decodes a compact ("bits") difficulty representation into a target.
    /// Mirrors Bitcoin Core's arith_uint256::SetCompact, including the
    /// negative/overflow rules. Returns nil for invalid encodings.
    static func target(compact bits: UInt32) -> UInt256? {
        let size = Int(bits >> 24)
        var word = UInt64(bits & 0x007F_FFFF)
        guard bits & 0x0080_0000 == 0 else { return nil } // negative target
        // Overflow rules from Core: mantissa must fit in size bytes within 256 bits.
        guard !(word != 0 && (size > 34 || (word > 0xFF && size > 33) || (word > 0xFFFF && size > 32))) else {
            return nil
        }
        if size <= 3 {
            word >>= UInt64(8 * (3 - size))
            return UInt256(word)
        }
        return UInt256(word).shiftedLeft(8 * (size - 3))
    }

    /// Proof-of-work contributed by one block at the given target
    /// (Bitcoin Core GetBlockProof): (~target / (target + 1)) + 1.
    /// Returns nil for a zero target.
    static func blockWork(target: UInt256) -> UInt256? {
        guard !target.isZero else { return nil }
        let numerator = UInt256.max - target
        let denominator = target + UInt256(1)
        return numerator.quotientAndRemainder(dividingBy: denominator).quotient + UInt256(1)
    }
}
