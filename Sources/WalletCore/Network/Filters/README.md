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

[The app](../../../WinnowApp/AppModel.swift) coordinates scanning with
[wallet state](../../Wallet/README.md),
[headers](../Headers/README.md), and
[peer selection](../Peers/README.md).

[FilterSync tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift) and
[adversarial peers](../../../../Tests/WalletCoreTests/Network/FilterSyncAdversaryTests.swift)
exercise verification, damaged progress, disagreement, and rollback.
[Core comparisons](../../../../Tests/DifferentialTests/FilterSyncDiffTests.swift) check
the scan against real node data.
