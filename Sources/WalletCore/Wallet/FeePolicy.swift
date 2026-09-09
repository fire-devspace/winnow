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
/// influence capped at `maximumPeerFloorSatPerVByte`. `resolve` returns the
/// rate on its own; `resolution` returns the same rate together with the floor
/// that cap held it under, when it held it under one.
///
/// Every supplied number is used only when it is finite and inside
/// `(0, maximumSatPerVByte]`; anything else is discarded and resolution falls
/// through to the next source, so no caller can drive this to a rate the
/// selector would refuse.
///
/// The peer floor is the one input that comes from strangers, and this fork
/// treats it as such (see `Wallet/README.md`). It is aggregated as the *lower
/// median over the pool's seats*, a seat that has sent nothing counting as 0
/// (`seatMajorityFloor`), rather than the maximum, and then capped, because a
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
    /// wallet will choose on its own — so the everyday market clears it with
    /// room to spare, and a floor beyond it stops being a number strangers
    /// get to choose.
    ///
    /// A cap rather than a rejection: a floor exists so a transaction relays
    /// at all, and discarding an implausible one outright would price a send
    /// under the network and strand it. Capped, the worst a lying pool can do
    /// is this number; uncapped, it was `maximumSatPerVByte`, three orders of
    /// magnitude higher and paid to miners.
    ///
    /// What the cap cannot do is tell an honest floor above it from a lie. A
    /// `feefilter` is unvalidated, so a mempool that has really settled at 200
    /// sat/vB and a majority of seats agreeing to say 200 arrive here as the
    /// same number, and both are priced at 120. Underpaying a real floor is
    /// not a cheaper send, it is a send that does not happen: `broadcast`
    /// returns a txid, no peer takes the bytes, and `Wallet.commit` has
    /// already marked the inputs spent, so the coins sit behind a payment
    /// going nowhere until the mempool's floor decays or the transaction is
    /// replaced. Nothing above the cap is ever paid on a stranger's say-so,
    /// but a caller has to be told, and `resolution` is what tells it: the
    /// clamped floor comes back beside the rate. An override is not capped,
    /// so a caller shown both numbers can still pay the floor in full.
    ///
    /// This is a fork-local policy. Upstream clamps by the peers' strictest
    /// filter with no ceiling; see `Wallet/README.md`.
    public static let maximumPeerFloorSatPerVByte: Double = 10 * Priority.high.satPerVByte

    /// A resolved feerate, and the peer floor it came out under when
    /// `maximumPeerFloorSatPerVByte` is what held it there.
    ///
    /// `clampedFloor` is the floor the pool reported, in sat/vB, and it is
    /// set only when `rate` is below it: the pool named a number past the
    /// cap, and nothing else in the resolution reaches that far. A floor the
    /// cap trimmed but the wallet's own numbers already cover reads as nil,
    /// because that send pays what the pool asked and relays.
    public struct Resolution: Equatable, Sendable {
        /// The feerate to price the send at (sat/vB).
        public let rate: Double
        /// The peer floor `rate` sits below (sat/vB), or nil when it does not.
        public let clampedFloor: Double?
    }

    /// Resolves the feerate to use (sat/vB). See the type doc for the order.
    /// `resolution` answers the same question and also reports a floor the
    /// cap priced the send under, which a bare `Double` cannot carry.
    public static func resolve(priority: Priority = .medium, override: Double? = nil,
                               estimated: Double? = nil, observed: [Double] = [],
                               floorSatPerVByte: Double? = nil) -> Double {
        resolution(priority: priority, override: override, estimated: estimated,
                   observed: observed, floorSatPerVByte: floorSatPerVByte).rate
    }

    /// Resolves the feerate (sat/vB) and says when the cap on the peer floor
    /// is what set it. See the type doc for the order.
    ///
    /// A caller handed a `clampedFloor` is being told the pool has said it
    /// will not relay at `rate`. It should refuse to build rather than commit
    /// coins to a transaction the network has already refused, because
    /// `Wallet` marks the inputs spent when it commits and forward-only
    /// scanning cannot take that back for a transaction that never left the
    /// device. Or it should put the two numbers in front of the person
    /// spending, since an override is not capped and someone who believes
    /// the floor can pay it.
    ///
    /// The library clamps and reports rather than refusing here. A
    /// `feefilter` is a claim a stranger makes about its own mempool, and a
    /// refusal at this layer would give a majority of seats willing to lie a
    /// veto over every send this wallet makes. Which of the two costs is
    /// worse depends on whether the money can wait, and the caller is the
    /// one that knows.
    public static func resolution(priority: Priority = .medium, override: Double? = nil,
                                  estimated: Double? = nil, observed: [Double] = [],
                                  floorSatPerVByte: Double? = nil) -> Resolution {
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
        // A floor outside the band is discarded rather than capped (`usable`),
        // so it clamps nothing and there is nothing to report about it.
        guard let floorSatPerVByte = usable(floorSatPerVByte) else {
            return Resolution(rate: base, clampedFloor: nil)
        }
        // The cap bounds what the floor can *add*, not what the caller may
        // pay: a user override or an observed median above it is untouched,
        // because those are this wallet's own numbers. Only the lift from a
        // stranger's advertised minimum is bounded.
        let rate = max(base, min(floorSatPerVByte, maximumPeerFloorSatPerVByte))
        return Resolution(rate: rate,
                          clampedFloor: rate < floorSatPerVByte ? floorSatPerVByte : nil)
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

    /// The floor a pool of `seats` peers agrees on, from the `feefilter`
    /// values the reporting peers have sent (sat/vB): the lower median over
    /// every seat, a seat with no announcement, whether nobody is sitting in
    /// it yet or its peer has simply not spoken, counted as 0. nil unless the
    /// result is a positive number.
    ///
    /// Over the seats, not over the reporters, because the reporters choose
    /// themselves. `median` over the peers that had spoken made the first
    /// voice decisive: in a pool of three with one filter in, the median of
    /// one number is that number, and with two in, the even-count average
    /// still moved the floor halfway to whatever the second peer named. A
    /// peer that has not sent a filter relays anything, so 0 is what its
    /// silence means for relay as well as for this count. Counted this way a
    /// floor needs more than half the seats to name a number at or above it,
    /// and the lower median rather than an average means the number is one
    /// some peer actually sent. A pool with a single seat is its own
    /// majority, which is the price of asking one peer.
    public static func seatMajorityFloor(reported: [Double], seats: Int) -> Double? {
        let count = max(seats, reported.count)
        guard count > 0 else { return nil }
        let sorted = (reported + Array(repeating: 0, count: count - reported.count)).sorted()
        let floor = sorted[(count - 1) / 2]
        return floor > 0 ? floor : nil
    }
}

extension PeerPool {
    /// The BIP133 `feefilter` floor a majority of this pool's seats agree on,
    /// in sat/vB (feefilter is sat/kvB): the lower median over `peerCount`
    /// seats, with every seat that has sent no filter, whether it is empty or
    /// its peer has not spoken, counted as 0. nil until more than half the
    /// seats have named a positive number (`FeePolicy.seatMajorityFloor`).
    ///
    /// Counted over the seats the pool is meant to fill, not over the peers
    /// that have reported, and that is this fork's choice rather than
    /// upstream's (`Wallet/README.md` records it). A `feefilter` is a number a
    /// peer asserts about its own mempool: nothing validates it, and the pool
    /// seats whoever answers. Taking the maximum handed the whole wallet's
    /// floor to whichever seated peer named the largest number, so one peer
    /// advertising an absurd filter priced every send at it — real money, paid
    /// to miners, for a claim nobody checked. A median of only the peers that
    /// had spoken was the same handover by another route: the first filter
    /// to arrive in a pool of three was the median of one, and a second
    /// honest one only averaged the liar down by half. A silent seat relays
    /// anything, so it honestly counts as 0, and a floor now needs a strict
    /// majority of the seats behind it before it moves, which is the same
    /// reasoning the filter checkpoint comparison already rests on;
    /// `FeePolicy` caps what even a unanimous pool can do with
    /// `maximumPeerFloorSatPerVByte`.
    ///
    /// The cost is the honest case where one peer is stricter than the others:
    /// a transaction at the majority's floor may not relay through that peer.
    /// It still relays through the rest of the pool, which is what
    /// broadcasting needs. Nothing names that peer: `TxBroadcaster` skips a
    /// peer whose filter refuses the rate rather than announcing into it, and
    /// says nothing about the one it skipped, so what shows the loss is the
    /// count in `.announced(txid:peerCount:)` coming back short of the seats.
    /// `.feeFloorExceeded` is the pool-wide signal and not the per-peer one:
    /// it fires when the *lowest* filter among the connected peers is above
    /// the rate, which is the case where no peer is left to relay at all. A
    /// pool that has not yet heard from most of its seats prices a send as if
    /// no floor were known, which is what it did before any filter arrived.
    /// In a relay-only session the seats are
    /// still `peerCount`, not the one seat the session kept, so the rule
    /// yields no floor there by design: a lone peer never sets the floor,
    /// whatever it announces.
    public func feeFilterFloorSatPerVByte() async -> Double? {
        var reported: [Double] = []
        for peer in connectedPeers() { // this extension method is already pool-isolated
            if let floor = await peer.feeFilter { reported.append(Double(floor) / 1_000) }
        }
        return FeePolicy.seatMajorityFloor(reported: reported, seats: peerCount)
    }
}

/// Consensus monetary range used at wallet authorization boundaries.
public enum BitcoinAmount {
    /// 21 million BTC in satoshis (`MAX_MONEY` in Bitcoin Core).
    public static let maximum: Int64 = 2_100_000_000_000_000
}
