[Back to main README](../../../../README.md)

# Verified block history

HeaderChain and its work arithmetic verify header links, proof of work, and
difficulty rules, persist progress, and report chain reorganizations.
Balances and confirmations need a validated chain to refer to.
Difficulty adjustments are calculated during sync, reorgs, and reloads. A start
at the mainnet checkpoint (900,000) lacks the beginning of the preceding period,
so the first adjustment at 901,152 cannot be calculated; 903,168 onward can.

[Filter scanning](../Filters/README.md) uses this
history. [Checkpoint generation](../../../../Tools/Generate/README.md) uses the same
validation code for the app's faster initial synchronization.

[HeaderChain tests](../../../../Tests/WalletCoreTests/Network/HeaderChainTests.swift) cover
forks, difficulty, checkpoints, and real header replay.
[Difficulty tests](../../../../Tests/WalletCoreTests/Network/HeaderDifficultyTests.swift)
compare Core's fixed answers and real mainnet adjustments, and reject wrong
targets in incoming batches, replacement branches, and saved files.
[Storage tests](../../../../Tests/WalletCoreTests/Network/HeaderStorageTests.swift) cover
corruption and recovery. Checkpoint assumptions and independent-review limits
remain documented in the [security evidence](../../../../docs/security/README.md).
