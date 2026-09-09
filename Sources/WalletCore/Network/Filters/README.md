[Back to main README](../../../../README.md)

# Private chain scanning

FilterSync asks peers for compact filters and retrieves matching blocks.
It lets the wallet find its confirmed payments without sending its addresses
to a remote indexer. Persisted progress and reorg rollback keep recovery usable.
A batch's matches and progress are committed only after the checkpoint headers
that batch pins agree with the peers' cfcheckpt answer, so a refused batch
leaves every store where it was.

Progress does not grow with the chain. Each batch persists only the pinned
filter headers a later check can still ask for: every checkpoint boundary, which
the cfcheckpt comparison reads on every sync, and the recent run a reorg could
rewind into, which ends at the anchor the next batch checks a peer's answer
against. Keeping that anchor is the condition, not the goal — with no anchor to
keep, nothing is pruned at all.

A batch of up to 1000 blocks stays the span peers are cross-checked over and
the span progress is saved after, but its filters are requested a chunk at a
time and matched as each chunk lands, so a scan holds one chunk rather than a
whole batch. A caller that cannot run to the tip in one go passes `maxBlocks`
to bound a single run; the next one resumes from the saved frontier.

Which peers are compared is a source-class decision at both layers rather than a
seating-order one: the `getcfcheckpt` round asks the same class-spanning set
`getcfheaders` does, so the comparison every later check is anchored to is not
settled by which peer connected first. What that set has to prove is this fork's
addition. `CrossCheckPolicy.requireDistinctSources` advances nothing unless peers
of at least two known acquisition channels agreed about the tip's filter
commitments, because the pool's ceiling does not imply that: manual peers are
exempt from the source rule, and the ceiling counts against the target seat count
rather than the connected one, so an all-manual pool and a pool sitting below
target each compare one channel against itself. A run that cannot meet it throws
`crossCheckUnavailable` having changed nothing. `acceptSingleSource` stays the
default and is the behaviour every caller had.

Either way a run records a `CrossCheckReceipt`: the tip it compared, a digest of
the answer it adopted, and the endpoints that gave that answer beside the class
the pool reached each of them through. `sync` returns it and `Progress` saves it
beside the frontier on the same commit, so a caller can say afterwards which
channels corroborated the state it is standing on instead of inferring it from
configuration that does not imply it. A degraded run writes an honest one-class
receipt rather than none. A rollback clears it, because it attests to a tip on
the branch that was just replaced.

## The restore-only range scan

Scanning is forward-only from the frontier, and `scanRange` is the one
exception to that, for a restore that finds a mnemonic and no wallet file:
there is no history to verify forward from and no birthday to start at, so the
blocks that hold the customer's payments are below every frontier the wallet
could name. It scans a bounded `[from, to]` for a watch set and never touches
the forward frontier — a separate record, in a separate file, with its own
resumable state.

Everything a batch is judged by is the forward path's, unchanged: the cfcheckpt
majority, the announced-count guard, the cross-check policy over who agreed (a
restore's coins are spend-relevant state, so `requireDistinctSources` refuses a
range scan on one channel before a filter is fetched, and the receipt is written
with every batch and returned on the outcome), the per-batch cfheaders
cross-check, the checkpoint-boundary comparison before a batch has any effect,
the per-filter header reproduction, and the chunked fetch with its byte bound. It does not
sync headers, so a caller that wants the back-scan pinned to a frozen recovery
checkpoint hands over a chain it does not advance; a range reaching below
`chain.startHeight` is refused by name, because filters are fetched by block
hash and a checkpoint-rooted chain holds no header to name one.

What makes the exception affordable is that every dimension of it is capped,
and each cap is clamped to a hard maximum on the way in rather than validated,
so a caller can ask for less and never for more (`RangeScanLimits`): blocks in
the range, scripts in one pass, compact-filter bytes in one run, wall-clock
time in one run, and passes over the range. The two spending caps refuse in a
way the caller can resume from — the record holds every batch that committed —
and the rest are decided before a peer is asked anything. The fixed-point loop
a restore needs (derive a gap of scripts, scan, derive more from what came
back, scan again) belongs to the caller; the pass cap is what bounds it.

[The app](../../../WinnowApp/AppModel.swift) coordinates scanning with
[wallet state](../../Wallet/README.md),
[headers](../Headers/README.md), and
[peer selection](../Peers/README.md).

[FilterSync tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift) and
[adversarial peers](../../../../Tests/WalletCoreTests/Network/FilterSyncAdversaryTests.swift)
exercise verification, damaged progress, disagreement, and rollback.
[Range-scan tests](../../../../Tests/WalletCoreTests/Network/RangeScanTests.swift)
cover the caps, the resumable record, and the untouched frontier.
[Core comparisons](../../../../Tests/DifferentialTests/FilterSyncDiffTests.swift) check
the scan against real node data.
