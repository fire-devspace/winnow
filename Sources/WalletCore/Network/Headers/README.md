[Back to main README](../../../../README.md)

# Verified block history

HeaderChain and its work arithmetic verify header links, proof of work, and
difficulty rules, persist progress, and report chain reorganizations.
Balances and confirmations need a validated chain to refer to.

[Filter scanning](../Filters/README.md) uses this
history. [Checkpoint generation](../../../../Tools/Generate/README.md) uses the same
validation code for the app's faster initial synchronization.

[HeaderChain tests](../../../../Tests/WalletCoreTests/Network/HeaderChainTests.swift) cover
forks, difficulty, checkpoints, and real header replay.
[Storage tests](../../../../Tests/WalletCoreTests/Network/HeaderStorageTests.swift) cover
corruption and recovery. Checkpoint assumptions and independent-review limits
remain documented in the [security evidence](../../../../docs/security/README.md).
