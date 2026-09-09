import Foundation

/// Why a restore-only range scan refused.
///
/// Every case is a refusal, never a truncation: a scan that has run out of a
/// cap throws rather than returning a short answer that reads like a complete
/// one. What separates them is whether the caller can resume. The two spending
/// caps (`filterBytesExhausted`, `runTimedOut`) leave the range record holding
/// every batch that committed before them, so the next call carries on from
/// there with a fresh budget. The shape refusals (`invalidRange`,
/// `rangeTooWide`, `tooManyScripts`, `tooManyIterations`, `rangeBelowChain`,
/// `rangeAboveChain`) are decided before any peer is asked, and they mean the
/// caller must change what it asked for; retrying the same call reproduces
/// them exactly.
public enum RangeScanError: LocalizedError, Equatable, Sendable {
    /// `from` is above `to`, or `to` is `UInt32.max`: a completed record has
    /// to be able to name the height after the last one it scanned.
    case invalidRange(from: UInt32, to: UInt32)
    /// A scan with nothing to look for. It would read every filter in the
    /// range and match nothing, which is the whole cost with none of the
    /// answer.
    case noWatchScripts
    case rangeTooWide(blocks: UInt64, limit: UInt32)
    case tooManyScripts(count: Int, limit: Int)
    case tooManyIterations(count: Int, limit: Int)
    case filterBytesExhausted(read: Int, limit: Int)
    case runTimedOut(limit: Duration)
    /// The range starts below the first block the header chain holds. On a
    /// checkpoint-rooted mainnet chain that floor is the pinned checkpoint
    /// (height 900,000): filters are fetched by block hash, and there is no
    /// header below the base to name one.
    case rangeBelowChain(from: UInt32, start: UInt32)
    case rangeAboveChain(to: UInt32, tip: UInt32)
    case recordUnreadable
    case recordTooLarge(maxBytes: Int)
    case recordDamaged(String)
    case recordWriteFailed

    public var errorDescription: String? {
        switch self {
        case let .invalidRange(from, to):
            "Winnow was asked to scan blocks \(from) to \(to), which is not a range it can scan."
        case .noWatchScripts:
            "A block range scan needs at least one script to look for."
        case let .rangeTooWide(blocks, limit):
            "That restore would scan \(blocks) blocks, past the \(limit)-block limit for one range."
        case let .tooManyScripts(count, limit):
            "That restore looks for \(count) scripts, past the limit of \(limit)."
        case let .tooManyIterations(count, limit):
            "That restore has already rescanned its range \(limit) time\(limit == 1 ? "" : "s") and asked for pass \(count)."
        case let .filterBytesExhausted(read, limit):
            "The restore scan reached its data limit (\(read) of \(limit) bytes of compact filters). It can be resumed."
        case let .runTimedOut(limit):
            "The restore scan reached its time limit (\(limit)). It can be resumed."
        case let .rangeBelowChain(from, start):
            "The restore scan starts at block \(from), below block \(start), which is the first block Winnow holds a header for."
        case let .rangeAboveChain(to, tip):
            "The restore scan ends at block \(to), above the validated chain tip \(tip)."
        case .recordUnreadable:
            "Winnow could not read the restore scan's progress file. The scan is stopped so a payment is not skipped."
        case let .recordTooLarge(maxBytes):
            "The restore scan's progress file is unexpectedly large (limit: \(maxBytes) bytes). The scan is stopped."
        case let .recordDamaged(reason):
            "The restore scan's progress file is damaged (\(reason)). The scan is stopped; Winnow will not replace it automatically."
        case .recordWriteFailed:
            "Winnow could not safely save the restore scan's progress. Nothing was recorded for this batch."
        }
    }
}

/// What bounds one restore-only range scan, and what bounds the restore it is
/// part of.
///
/// This is a fork-local addition, and the caps are the reason it can exist at
/// all. Upstream is forward-only on purpose (docs/mobile.html section 4.1):
/// a wallet scans from its birthday to the tip and never back, because a
/// historical back-scan on a phone is unbounded work on a radio the customer
/// pays for. A restore that has a mnemonic and no wallet file has no birthday
/// to scan forward from, so this fork needs the back-scan — and what makes it
/// something other than the unbounded scan upstream refused is that every
/// dimension of it is capped, by a number that cannot be raised past a hard
/// maximum stated here.
///
/// Each value is clamped to its ceiling on the way in rather than validated,
/// so a caller cannot loosen a cap by asking for more; asking for less always
/// works. The ceilings are:
///
/// - `blocksCeiling`, five years of mainnet blocks at 52,560 a year. A restore
///   range is [birthday, frontier], and Fire's floor for a wallet with no
///   recovery record is the launch height, so five years is comfortably past
///   the oldest range this can be asked for and still refuses a scan of the
///   whole chain.
/// - `scriptsCeiling`, 200 windows of the 100-index restore gap. Matching is
///   linear in the script set for every filter in the range, so this is the
///   cap that decides how much CPU a pass costs.
/// - `filterBytesCeiling`, 1 GiB of compact filters in one run. Mainnet
///   filters run 15-20 KB a block, so the default 64 MiB is roughly 3,500
///   blocks: a run a phone can finish on a cellular connection, after which
///   the caller decides whether to spend more.
/// - `durationCeiling`, an hour. Checked between chunks and between batches,
///   so a run can overshoot by at most one outstanding peer request; this
///   bounds how long a restore may hold the pool, not how long a request takes.
/// - `iterationsCeiling`, 50 passes over the range. A pass is one fixed-point
///   step: the caller derives more scripts from what the last pass found and
///   scans the range again. Honest restores converge in two or three.
///
/// What bounds the whole restore, rather than one run, is `maxBlocks` and
/// `maxIterations` together. A run that refuses on bytes or time resumes from
/// the last batch that committed, so what it re-reads is the batch it died
/// inside and never the range: the filter traffic of a whole restore is the
/// range read `maxIterations` times, plus one batch for each interruption.
public struct RangeScanLimits: Sendable, Equatable {
    public static let blocksCeiling: UInt32 = 262_800
    public static let scriptsCeiling = 20_000
    public static let filterBytesCeiling = 1_024 * 1_024 * 1_024
    public static let durationCeiling: Duration = .seconds(3_600)
    public static let iterationsCeiling = 50

    /// Blocks in [from, to], inclusive.
    public let maxBlocks: UInt32
    /// Watch scripts one pass may look for.
    public let maxScripts: Int
    /// Compact-filter bytes one run may read before it refuses.
    public let maxFilterBytes: Int
    /// Wall-clock time one run may take before it refuses.
    public let maxDuration: Duration
    /// Passes over the range one record may accumulate.
    public let maxIterations: Int

    public init(maxBlocks: UInt32 = 105_120,
                maxScripts: Int = 2_000,
                maxFilterBytes: Int = 64 * 1_024 * 1_024,
                maxDuration: Duration = .seconds(300),
                maxIterations: Int = 10) {
        self.maxBlocks = min(maxBlocks, Self.blocksCeiling)
        self.maxScripts = min(max(0, maxScripts), Self.scriptsCeiling)
        self.maxFilterBytes = min(max(0, maxFilterBytes), Self.filterBytesCeiling)
        self.maxDuration = min(max(.zero, maxDuration), Self.durationCeiling)
        self.maxIterations = min(max(0, maxIterations), Self.iterationsCeiling)
    }
}

/// A range scan's persisted, resumable progress. Its own record, in its own
/// file: nothing here is the forward scan frontier, and a range scan never
/// reads or writes that frontier.
///
/// The record names the range and the script set it describes, because both
/// decide what resuming means. Same range and same scripts is a resumption,
/// and it starts at `nextScanHeight`. Same range and a different script set is
/// the next fixed-point pass, so the frontier goes back to `from` and
/// `iteration` counts up; the pinned headers below `from` are kept, since the
/// anchor at `from - 1` is what refuses a peer whose announced filter chain
/// does not continue the one an earlier pass verified. A different range is a
/// different scan and replaces the record, because a record can describe only
/// one range and keeping the old one would resume the wrong blocks.
public struct RangeScanProgress: Codable, Sendable, Equatable {
    /// First height of the range, inclusive.
    public var from: UInt32
    /// Last height of the range, inclusive.
    public var to: UInt32
    /// Next height inside the range whose filter must be read. `to + 1` when
    /// the range is finished.
    public var nextScanHeight: UInt32
    /// SHA256d over the sorted watch scripts this record was scanned with.
    public var watchFingerprint: String
    /// Which fixed-point pass over the range this is, counting from one.
    public var iteration: Int
    /// Pinned filter headers: decimal height to hex (internal byte order),
    /// pruned exactly as the forward scan prunes its own.
    public var filterHeaders: [String: String]

    public init(from: UInt32, to: UInt32, nextScanHeight: UInt32,
                watchFingerprint: String, iteration: Int,
                filterHeaders: [String: String] = [:]) {
        self.from = from
        self.to = to
        self.nextScanHeight = nextScanHeight
        self.watchFingerprint = watchFingerprint
        self.iteration = iteration
        self.filterHeaders = filterHeaders
    }

    /// Whether every block in [from, to] has been scanned by this pass.
    public var isComplete: Bool { nextScanHeight > to }

    /// Highest height this pass has scanned, or nil when it has committed no
    /// batch yet.
    public var scannedThrough: UInt32? { nextScanHeight > from ? nextScanHeight - 1 : nil }

    /// The record for the next fixed-point pass: the same range, read again
    /// from the start with a larger script set.
    func restarted(fingerprint: String) -> RangeScanProgress {
        let start = from
        return RangeScanProgress(
            from: from, to: to, nextScanHeight: from,
            watchFingerprint: fingerprint, iteration: iteration + 1,
            filterHeaders: filterHeaders.filter { key, _ in
                guard let height = UInt32(key) else { return false }
                return height < start
            })
    }

    /// One identity for a watch set, order-independent: the scripts as sorted
    /// hex, newline-separated, hashed. A different set means a different pass
    /// over the range, and this is what tells the two apart across a process
    /// that stopped in between.
    public static func fingerprint(of watchScripts: [Data]) -> String {
        var joined = Data()
        for script in watchScripts.map(\.hex).sorted() {
            joined.append(contentsOf: Array(script.utf8))
            joined.append(0x0A)
        }
        return SHA256d.hash(joined).hex
    }

    /// The record stored at `storageURL`, or nil when there is none. Damage is
    /// reported, never repaired: a record that cannot be read is not replaced
    /// with a fresh one, because "start over" and "resume" differ by exactly
    /// the blocks a restore would then skip.
    public static func load(storageURL: URL?) throws -> RangeScanProgress? {
        guard let storageURL,
              FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        try checkSize(at: storageURL)
        let data: Data
        do {
            data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
        } catch {
            throw RangeScanError.recordUnreadable
        }
        guard data.count <= FilterSync.rangeRecordMaxBytes else {
            throw RangeScanError.recordTooLarge(maxBytes: FilterSync.rangeRecordMaxBytes)
        }
        let stored: RangeScanProgress
        do {
            stored = try JSONDecoder().decode(RangeScanProgress.self, from: data)
        } catch {
            throw RangeScanError.recordDamaged("the JSON or a progress field is invalid")
        }
        try stored.validate()
        return stored
    }

    private static func checkSize(at storageURL: URL) throws {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: storageURL.path) else {
            throw RangeScanError.recordUnreadable
        }
        if let size = attributes[.size] as? NSNumber,
           size.int64Value > Int64(FilterSync.rangeRecordMaxBytes) {
            throw RangeScanError.recordTooLarge(maxBytes: FilterSync.rangeRecordMaxBytes)
        }
    }

    func validate() throws {
        guard from <= to, nextScanHeight >= from,
              UInt64(nextScanHeight) <= UInt64(to) + 1 else {
            throw RangeScanError.recordDamaged("the range and its frontier disagree")
        }
        guard iteration >= 1 else {
            throw RangeScanError.recordDamaged("the pass number is below one")
        }
        guard Data(hex: watchFingerprint)?.count == 32 else {
            throw RangeScanError.recordDamaged("the watch-script fingerprint is not 32 bytes")
        }
        try Self.validate(filterHeaders: filterHeaders, below: nextScanHeight)
    }

    /// The same rules the forward progress file is held to: canonical decimal
    /// heights, no duplicates, 32-byte headers, and nothing pinned at or above
    /// the frontier it claims to have scanned to.
    private static func validate(filterHeaders: [String: String], below frontier: UInt32) throws {
        guard filterHeaders.count <= FilterSync.rangeRecordMaxPinnedHeaders else {
            throw RangeScanError.recordDamaged("there are too many pinned filter headers")
        }
        var parsed = Set<UInt32>()
        parsed.reserveCapacity(filterHeaders.count)
        for (key, value) in filterHeaders {
            guard let height = UInt32(key), String(height) == key else {
                throw RangeScanError.recordDamaged("a filter-header height is not canonical decimal")
            }
            guard parsed.insert(height).inserted else {
                throw RangeScanError.recordDamaged("two filter-header keys name the same height")
            }
            guard height < frontier else {
                throw RangeScanError.recordDamaged("a pinned filter header is at or beyond the scan frontier")
            }
            guard value.utf8.count == 64, Data(hex: value)?.count == 32 else {
                throw RangeScanError.recordDamaged("a pinned filter header is not 32 bytes")
            }
        }
    }

    func persist(to storageURL: URL?) throws {
        guard let storageURL else { return }
        let data = try JSONEncoder().encode(self)
        guard data.count <= FilterSync.rangeRecordMaxBytes else {
            throw RangeScanError.recordTooLarge(maxBytes: FilterSync.rangeRecordMaxBytes)
        }
        do {
            try data.write(to: storageURL,
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw RangeScanError.recordWriteFailed
        }
    }

    /// The record a run starts from: the stored one resumed, the stored one
    /// restarted for a new script set, or a fresh one. The pass cap is
    /// checked here, before any peer is asked.
    static func resumed(stored: RangeScanProgress?, from: UInt32, to: UInt32,
                        fingerprint: String, limits: RangeScanLimits) throws -> RangeScanProgress {
        var record = RangeScanProgress(from: from, to: to, nextScanHeight: from,
                                       watchFingerprint: fingerprint, iteration: 1)
        if let stored, stored.from == from, stored.to == to {
            record = stored.watchFingerprint == fingerprint
                ? stored
                : stored.restarted(fingerprint: fingerprint)
        }
        guard record.iteration <= limits.maxIterations else {
            throw RangeScanError.tooManyIterations(count: record.iteration,
                                                   limit: limits.maxIterations)
        }
        return record
    }
}

/// What one range-scan run has spent and how much it has left. Held on the
/// actor for the length of a run so the filter-chunk loop can be refused from
/// inside, which is what makes the byte and time caps bounds on a run rather
/// than on a batch.
struct RangeScanRun: Sendable {
    let deadline: ContinuousClock.Instant
    let maxDuration: Duration
    let maxFilterBytes: Int
    private(set) var filterBytesRead = 0
    private(set) var matchedHeights: [UInt32] = []

    init(limits: RangeScanLimits, now: ContinuousClock.Instant = .now) {
        deadline = now.advanced(by: limits.maxDuration)
        maxDuration = limits.maxDuration
        maxFilterBytes = limits.maxFilterBytes
    }

    func checkDeadline(now: ContinuousClock.Instant = .now) throws {
        guard now < deadline else { throw RangeScanError.runTimedOut(limit: maxDuration) }
    }

    /// Charges a chunk's filter bytes and refuses if that took the run past
    /// its cap. Charged after the chunk has arrived and been matched, so the
    /// overshoot is one chunk, which `FilterSync.chunkByteBound(filters:)`
    /// already bounds on the wire.
    mutating func charge(filterBytes: Int) throws {
        filterBytesRead += filterBytes
        guard filterBytesRead <= maxFilterBytes else {
            throw RangeScanError.filterBytesExhausted(read: filterBytesRead,
                                                      limit: maxFilterBytes)
        }
    }

    mutating func note(matchAt height: UInt32) {
        matchedHeights.append(height)
    }
}

/// What one range-scan run did. The blocks themselves go to `onMatch` as they
/// are found, exactly as the forward scan delivers them, because a restore
/// range can match more blocks than a phone should hold at once; what comes
/// back here is the bookkeeping a caller needs to decide whether to run again.
public struct RangeScanOutcome: Sendable, Equatable {
    public let from: UInt32
    public let to: UInt32
    /// Heights delivered to `onMatch` by THIS run. A resumed run reports what
    /// it found, not what earlier runs found.
    public let matchedHeights: [UInt32]
    /// Highest height the record has scanned to, over every run of this pass.
    public let scannedThrough: UInt32?
    /// Whether [from, to] is now covered by this pass.
    public let isComplete: Bool
    /// Which fixed-point pass this run belonged to.
    public let iteration: Int
    /// Compact-filter bytes this run read, which is what the byte cap counts.
    public let filterBytesRead: Int
}

extension FilterSync {
    /// The most bytes a range record's file may be. Pruning holds a record to
    /// a few thousand pinned headers, which is a couple of hundred kilobytes;
    /// this is far above that and far below anything that would matter to
    /// memory, and it exists so a replaced or corrupted file is refused
    /// rather than decoded.
    public static let rangeRecordMaxBytes = 16 * 1_024 * 1_024
    /// The most pinned headers a range record may carry, for the same reason
    /// the forward progress file has one.
    public static let rangeRecordMaxPinnedHeaders = 2_000_000

    /// Scans [from, to] for `watchScripts` without moving the forward scan
    /// frontier: the restore-only back-scan, and the one entry point in this
    /// file that a caller uses.
    ///
    /// This exists for one situation. A customer restores from a mnemonic and
    /// has no wallet file, so there is no history to verify forward from and
    /// no birthday to start at. The caller picks a floor (a recovery record's
    /// birthday, or the frozen launch height), derives a gap of scripts, scans
    /// the range for them, derives more from what came back, and scans again
    /// until a pass finds nothing new. This call is one pass, or one run of
    /// one pass; the loop and the decision to run it again belong to the
    /// caller, and `RangeScanLimits` is what stops the loop being unbounded.
    ///
    /// **The header chain is read, never advanced.** There is no `syncHeaders`
    /// here, so a caller that wants the back-scan pinned to a frozen recovery
    /// checkpoint simply hands over a chain it does not sync. The range must
    /// be inside what that chain holds: below `chain.startHeight` there are no
    /// headers, and filters are fetched by block hash, so a range that reaches
    /// under the base is refused with `rangeBelowChain` rather than failing
    /// later as a missing header. On mainnet that floor is the pinned
    /// checkpoint at height 900,000.
    ///
    /// Everything a batch is judged by is the forward path's, unchanged: the
    /// cfcheckpt majority across peers, the announced-count guard tied to the
    /// tip, the cfheaders cross-check per batch, the checkpoint-boundary
    /// comparison before a batch has any effect, the per-filter header
    /// reproduction, and the chunked fetch with its byte bound. A batch that
    /// fails any of them commits nothing and the record stays where it was.
    ///
    /// Progress goes to `storageURL`, which must not be the forward progress
    /// file — it is a different record with a different shape, and a range
    /// scan neither reads nor writes the forward frontier. Nil keeps the whole
    /// scan in memory, which means an interrupted run starts over.
    ///
    /// A run interrupted by a cap or a peer fault leaves the record at the
    /// last batch that committed, so the blocks of the batch it died inside
    /// are read again by the next run and their matches delivered again.
    /// `onMatch` must therefore be idempotent per height, which is the same
    /// contract the forward scan's already has.
    ///
    /// A record describes the chain it was scanned against, and nothing here
    /// rolls one back. If the header chain is replaced under a record between
    /// two runs — which takes a caller advancing it, since this call never
    /// does — the pinned anchor below the resumed frontier no longer continues
    /// what a peer announces, and the first batch of the next run fails closed
    /// with `filterHeaderMismatch` rather than reading blocks off a branch
    /// that is gone. Starting a fresh restore means deleting the record, not
    /// scanning over it.
    ///
    /// One run at a time, and it shares that rule with `sync`: both take the
    /// same flag, so a range scan while a forward sync is running (or the
    /// other way round) throws `syncAlreadyRunning` having changed nothing.
    /// They would otherwise share one pool, and peer replies go to whichever
    /// collector expects the command first.
    @discardableResult
    public func scanRange(from: UInt32, to: UInt32,
                          watchScripts: [Data],
                          limits: RangeScanLimits = RangeScanLimits(),
                          storageURL: URL? = nil,
                          onMatch: @Sendable (BlockMatch) async throws -> Void) async throws
        -> RangeScanOutcome
    {
        guard !isSyncing else { throw FilterSyncError.syncAlreadyRunning }
        isSyncing = true
        defer {
            isSyncing = false
            rangeRun = nil
        }
        try Self.checkShape(from: from, to: to, watchScripts: watchScripts, limits: limits)
        // Same refusal as `sync`, for the same reason: a pool holding seats so
        // a signed payment can go out is not a pool to read a restore over.
        guard await pool.mode == .full else { throw FilterSyncError.relayOnly }
        let tip = await chain.height
        try Self.checkChain(from: from, to: to, start: await chain.startHeight, tip: tip)

        var record = try RangeScanProgress.resumed(
            stored: RangeScanProgress.load(storageURL: storageURL),
            from: from, to: to,
            fingerprint: RangeScanProgress.fingerprint(of: watchScripts),
            limits: limits)
        rangeRun = RangeScanRun(limits: limits)
        if !record.isComplete {
            record = try await runRange(record, tip: tip, watchScripts: watchScripts,
                                        storageURL: storageURL, onMatch: onMatch)
        }
        return RangeScanOutcome(from: from, to: to,
                                matchedHeights: rangeRun?.matchedHeights ?? [],
                                scannedThrough: record.scannedThrough,
                                isComplete: record.isComplete,
                                iteration: record.iteration,
                                filterBytesRead: rangeRun?.filterBytesRead ?? 0)
    }

    /// The batch loop, which is the forward scan's with the range's own record
    /// in place of the frontier and no reorg handling (the chain is not being
    /// advanced, so nothing can fork underneath it).
    private func runRange(_ initial: RangeScanProgress, tip: UInt32,
                          watchScripts: [Data], storageURL: URL?,
                          onMatch: @Sendable (BlockMatch) async throws -> Void) async throws
        -> RangeScanProgress
    {
        let (reference, approvedEndpoints) = try await rangeReference(tip: tip)
        try Self.checkPinnedBoundaries(of: initial.filterHeaders, against: reference, tip: tip)
        var peers = try await approved(peers: approvedEndpoints)
        var record = initial
        let collect: @Sendable (BlockMatch) async throws -> Void = { match in
            await self.note(matchAt: match.height)
            try await onMatch(match)
        }
        while record.nextScanHeight <= record.to {
            try checkRangeDeadline()
            let batchStart = record.nextScanHeight
            let batchStop = UInt32(min(UInt64(batchStart) + UInt64(Self.maxRangePerRequest) - 1,
                                       UInt64(record.to)))
            guard let stopHash = await chain.blockHash(at: batchStop) else {
                throw FilterSyncError.badPeerResponse("missing header at \(batchStop)")
            }
            let proposed = try await pinFilterHeaders(
                batchStart: batchStart, batchStop: batchStop, stopHash: stopHash,
                peers: peers, startingFrom: record.filterHeaders)
            // Before the batch has any effect, exactly as the forward path
            // does it: a batch whose checkpoint boundaries disagree with the
            // announced cfcheckpt delivers no match and persists nothing.
            try Self.checkPinnedBoundaries(of: proposed, against: reference, tip: tip)
            // Re-derived because the cross-check may have just disconnected
            // the peer at the front of the list.
            peers = try await approved(peers: approvedEndpoints)
            try await scanFilters(batchStart: batchStart, batchStop: batchStop, peer: peers[0],
                                  watchScripts: watchScripts, filterHeaders: proposed,
                                  onMatch: collect)
            var candidate = record
            candidate.nextScanHeight = batchStop + 1
            candidate.filterHeaders = Self.prunedFilterHeaders(proposed,
                                                               frontier: candidate.nextScanHeight)
            try candidate.persist(to: storageURL)
            record = candidate
        }
        return record
    }

    /// The cfcheckpt reference for a range scan and the peers that gave it:
    /// the same collection, the same majority rule and the same
    /// announced-count guard the forward scan runs, against the chain as it
    /// stands rather than one just synced.
    private func rangeReference(tip: UInt32) async throws
        -> (reference: CFCheckptMessage, approved: Set<String>)
    {
        let peers = await pool.connectedPeers()
        guard !peers.isEmpty else {
            let cooling = await pool.coolingEndpoints.count
            throw cooling > 0 ? FilterSyncError.peersCoolingDown(cooling) : FilterSyncError.noPeers
        }
        let checkpoints = try await collectedCheckpoints(from: peers, tipHash: await chain.tipHash)
        let reference = try await majorityReference(of: checkpoints)
        let expected = Int(tip / Self.checkpointInterval)
        guard reference.filterHeaders.count == expected else {
            throw FilterSyncError.checkpointMismatch(
                "cfcheckpt announced \(reference.filterHeaders.count) checkpoints for tip \(tip), expected \(expected)")
        }
        let endpoints = await Self.endpoints(
            of: checkpoints.filter { $0.message == reference }.map(\.peer))
        return (reference, endpoints)
    }

    /// Everything about the request that can be judged before a peer is
    /// asked anything.
    static func checkShape(from: UInt32, to: UInt32, watchScripts: [Data],
                           limits: RangeScanLimits) throws {
        guard from <= to, to < UInt32.max else {
            throw RangeScanError.invalidRange(from: from, to: to)
        }
        guard !watchScripts.isEmpty else { throw RangeScanError.noWatchScripts }
        let blocks = UInt64(to) - UInt64(from) + 1
        guard blocks <= UInt64(limits.maxBlocks) else {
            throw RangeScanError.rangeTooWide(blocks: blocks, limit: limits.maxBlocks)
        }
        guard watchScripts.count <= limits.maxScripts else {
            throw RangeScanError.tooManyScripts(count: watchScripts.count, limit: limits.maxScripts)
        }
    }

    /// The range must be inside the headers we hold. Both ends are refused by
    /// name rather than left to fail as a missing block hash mid-batch.
    static func checkChain(from: UInt32, to: UInt32, start: UInt32, tip: UInt32) throws {
        guard from >= start else {
            throw RangeScanError.rangeBelowChain(from: from, start: start)
        }
        guard to <= tip else { throw RangeScanError.rangeAboveChain(to: to, tip: tip) }
    }

    // MARK: - The run's budget, consulted from the filter-chunk loop

    /// No-ops on the forward path, where `rangeRun` is nil and the caller's
    /// `maxBlocks` is the bound instead.
    func checkRangeDeadline() throws {
        try rangeRun?.checkDeadline()
    }

    func chargeRangeFilterBytes(_ bytes: Int) throws {
        try rangeRun?.charge(filterBytes: bytes)
    }

    private func note(matchAt height: UInt32) {
        rangeRun?.note(matchAt: height)
    }
}
