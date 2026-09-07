import Foundation

/// A SplitMix64 generator: the same generator as `WinnowFuzz`, so a failing
/// case can be replayed there, and deterministic so a failure names the seed
/// and iteration that reproduce it exactly.
public struct SeededRandom: RandomNumberGenerator {
    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// A draw inside `range`, inclusive of both ends.
    public mutating func int(_ range: ClosedRange<Int64>) -> Int64 {
        let span = UInt64(range.upperBound - range.lowerBound) &+ 1
        return range.lowerBound &+ Int64(next() % max(span, 1))
    }

    /// A draw in `0 ..< max(upperBound, 1)`.
    public mutating func count(_ upperBound: Int) -> Int { Int(next() % UInt64(max(upperBound, 1))) }

    /// A draw in `0 ..< bound`; zero for a bound of zero or less.
    public mutating func below(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }

    public mutating func pick<T>(_ options: [T]) -> T { options[below(options.count)] }

    public mutating func bytes(_ count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8(next() & 0xFF) })
    }
}
