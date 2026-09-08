import Foundation

/// Feerate resolution (docs/write-side.md §4; the read-side names the
/// blindness as weakness 4). Resolution order, strongest first:
///
/// 1. an explicit **user override** (sat/vB);
/// 2. an optional **estimate supplied by the embedder** (fork-local: upstream
///    deliberately has no fee-market estimator, so nothing in this package
///    produces one and the parameter defaults to nil), never taken below the
///    observed median under it;
/// 3. the **median feerate observed** from the wallet's own recently confirmed
///    transactions (the only feerates a filter-only client can compute exactly,
///    since it knows all input amounts);
/// 4. conservative **static presets** per priority;
///
/// …with the result always clamped from below by the peers' BIP133 `feefilter`
/// floor (the minimum a transaction must pay to relay at all).
///
/// Every supplied number is used only when it is finite and inside
/// `(0, maximumSatPerVByte]`; anything else is discarded and resolution falls
/// through to the next source, so no caller can drive this to a rate the
/// selector would refuse.
public enum FeePolicy {
    public enum Priority: String, CaseIterable, Sendable {
        case low, medium, high

        /// Conservative static presets (sat/vB), used when nothing is observed.
        /// Deliberately above typical minima — a mempool-blind wallet must
        /// overpay rather than stall.
        public var satPerVByte: Double {
            switch self {
            case .low: 2
            case .medium: 5
            case .high: 12
            }
        }
    }

    /// The largest feerate resolution will return (sat/vB): the top of the band
    /// `CoinSelection` accepts, restated here so the two fee gates cannot
    /// disagree about which numbers exist.
    public static let maximumSatPerVByte: Double = 10_000

    /// Resolves the feerate to use (sat/vB). See the type doc for the order.
    public static func resolve(priority: Priority = .medium, override: Double? = nil,
                               estimated: Double? = nil, observed: [Double] = [],
                               floorSatPerVByte: Double? = nil) -> Double {
        let samples = observed.compactMap { usable($0) }
        let base: Double
        if let override = usable(override) {
            base = override
        } else if let estimated = usable(estimated) {
            // Somebody else's number: better informed than a handful of local
            // samples, but it may not price this wallet below the feerates it
            // has itself paid and seen confirm.
            base = max(estimated, median(samples) ?? 0)
        } else {
            base = median(samples) ?? priority.satPerVByte
        }
        guard let floorSatPerVByte = usable(floorSatPerVByte) else { return base }
        return max(base, floorSatPerVByte)
    }

    /// A feerate counts only inside `(0, maximumSatPerVByte]`. A missing, NaN,
    /// infinite, negative, zero or absurd value is dropped rather than clamped:
    /// falling through to a source we trust beats turning a typo or a hostile
    /// peer's number into a plausible-looking fee.
    private static func usable(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0, rate <= maximumSatPerVByte else { return nil }
        return rate
    }

    /// Median of the observed samples (nil when empty).
    public static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension PeerPool {
    /// The strictest BIP133 `feefilter` among connected peers, in sat/vB
    /// (feefilter is sat/kvB). nil when no peer has sent one.
    public func feeFilterFloorSatPerVByte() async -> Double? {
        var floors: [Int64] = []
        for peer in connectedPeers() { // this extension method is already pool-isolated
            if let floor = await peer.feeFilter { floors.append(floor) }
        }
        guard let strictest = floors.max() else { return nil }
        return Double(strictest) / 1_000
    }
}

/// Consensus monetary range used at wallet authorization boundaries.
public enum BitcoinAmount {
    /// 21 million BTC in satoshis (`MAX_MONEY` in Bitcoin Core).
    public static let maximum: Int64 = 2_100_000_000_000_000
}
