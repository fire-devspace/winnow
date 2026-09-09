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

[The app](../../../WinnowApp/AppModel.swift) coordinates scanning with
[wallet state](../../Wallet/README.md),
[headers](../Headers/README.md), and
[peer selection](../Peers/README.md).

[FilterSync tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift) and
[adversarial peers](../../../../Tests/WalletCoreTests/Network/FilterSyncAdversaryTests.swift)
exercise verification, damaged progress, disagreement, and rollback.
[Core comparisons](../../../../Tests/DifferentialTests/FilterSyncDiffTests.swift) check
the scan against real node data.
