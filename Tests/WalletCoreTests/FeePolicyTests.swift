import BitcoinP2P
import Foundation
import Testing
@testable import WalletCore

@Suite("Fee policy")
struct FeePolicyTests {
    @Test("resolution order: override > observed median > static preset")
    func order() {
        // Static presets when nothing else is known.
        #expect(FeePolicy.resolve(priority: .low) == FeePolicy.Priority.low.satPerVByte)
        #expect(FeePolicy.resolve(priority: .medium) == 5)
        #expect(FeePolicy.resolve(priority: .high) == 12)
        // Observed median beats the preset.
        #expect(FeePolicy.resolve(priority: .high, observed: [3, 7, 4]) == 4)
        // The user override beats everything.
        #expect(FeePolicy.resolve(priority: .high, override: 42, observed: [3, 7, 4]) == 42)
    }

    @Test("the feefilter floor clamps every source from below")
    func floor() {
        #expect(FeePolicy.resolve(priority: .low, floorSatPerVByte: 3.5) == 3.5)
        #expect(FeePolicy.resolve(priority: .low, override: 1, floorSatPerVByte: 2) == 2)
        #expect(FeePolicy.resolve(observed: [10], floorSatPerVByte: 1) == 10) // above floor: untouched
    }

    @Test("median of observed samples")
    func median() {
        #expect(FeePolicy.median([]) == nil)
        #expect(FeePolicy.median([5]) == 5)
        #expect(FeePolicy.median([1, 9, 3]) == 3)
        #expect(FeePolicy.median([1, 3, 9, 5]) == 4)
    }

    @Test("a peer pool with no connected peers has no floor")
    func poolFloor() async {
        let pool = PeerPool(params: .signet)
        #expect(await pool.feeFilterFloorSatPerVByte() == nil)
    }
}
