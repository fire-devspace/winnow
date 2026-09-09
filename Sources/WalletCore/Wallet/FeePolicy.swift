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
/// floor (the minimum a transaction must pay to relay at all), and that floor's
/// influence capped at `maximumPeerFloorSatPerVByte`.
///
/// Every supplied number is used only when it is finite and inside
/// `(0, maximumSatPerVByte]`; anything else is discarded and resolution falls
/// through to the next source, so no caller can drive this to a rate the
/// selector would refuse.
///
/// The peer floor is the one input that comes from strangers, and this fork
/// treats it as such (see `Wallet/README.md`). It is aggregated as the *median*
/// of connected peers rather than the maximum, and then capped, because a
/// `feefilter` is an unvalidated number a peer sends about itself: taking the
/// maximum let any one seated peer set the floor for the whole wallet, and
/// `usable` accepts anything up to `maximumSatPerVByte`, so the worst case was
/// a real send priced at 10,000 sat/vB — a fee larger than most payments, paid
/// to miners, on the word of one connection.
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

    /// The most a peer-supplied `feefilter` floor may lift the resolved rate
    /// (sat/vB). Ten times the high preset — the most expensive number this
    /// wallet will choose on its own — so an honest floor in any market this
    /// client can price for still applies in full, and a floor beyond it
    /// stops being a number strangers get to choose.
    ///
    /// A cap rather than a rejection: a floor exists so a transaction relays
    /// at all, and discarding an implausible one outright would price a send
    /// under the network and strand it. Capped, the worst a lying pool can do
    /// is this number; uncapped, it was `maximumSatPerVByte`, three orders of
    /// magnitude higher and paid to miners.
    ///
    /// This is a fork-local policy. Upstream clamps by the peers' strictest
    /// filter with no ceiling; see `Wallet/README.md`.
    public static let maximumPeerFloorSatPerVByte: Double = 10 * Priority.high.satPerVByte

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
        // The cap bounds what the floor can *add*, not what the caller may
        // pay: a user override or an observed median above it is untouched,
        // because those are this wallet's own numbers. Only the lift from a
        // stranger's advertised minimum is bounded.
        return max(base, min(floorSatPerVByte, maximumPeerFloorSatPerVByte))
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
    /// The typical BIP133 `feefilter` among connected peers, in sat/vB
    /// (feefilter is sat/kvB). nil when no peer has sent one.
    ///
    /// The median, not the maximum, and that is this fork's choice rather than
    /// upstream's (`Wallet/README.md` records it). A `feefilter` is a number a
    /// peer asserts about its own mempool: nothing validates it, and the pool
    /// seats whoever answers. Taking the maximum handed the whole wallet's
    /// floor to whichever seated peer named the largest number, so one peer
    /// advertising an absurd filter priced every send at it — real money, paid
    /// to miners, for a claim nobody checked. The median needs most of the
    /// pool to agree before it moves, which is the same reasoning the filter
    /// checkpoint comparison already rests on, and `FeePolicy` caps what even
    /// a unanimous pool can do with `maximumPeerFloorSatPerVByte`.
    ///
    /// The cost is the honest case where one peer is stricter than the others:
    /// a transaction at the median may not relay through that peer. It still
    /// relays through the rest of the pool, which is what broadcasting needs,
    /// and `TxBroadcaster` already reports `feeFloorExceeded` per peer.
    public func feeFilterFloorSatPerVByte() async -> Double? {
        var floors: [Double] = []
        for peer in connectedPeers() { // this extension method is already pool-isolated
            if let floor = await peer.feeFilter { floors.append(Double(floor) / 1_000) }
        }
        return FeePolicy.median(floors)
    }
}

/// Consensus monetary range used at wallet authorization boundaries.
public enum BitcoinAmount {
    /// 21 million BTC in satoshis (`MAX_MONEY` in Bitcoin Core).
    public static let maximum: Int64 = 2_100_000_000_000_000
}
