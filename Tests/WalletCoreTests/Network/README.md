[Back to main README](../../../README.md)

# Wallet networking tests

This group tests the networking code inside WalletCore: headers, compact-filter
scans, peer policy, wire parsing, mempool windows, and payment relay.
A wallet needs both accurate balances and understandable recovery from peer faults.

[Controlled peers](../../Support/P2P/README.md) supply forks, disconnects,
and adversarial answers. The tests are part of WalletCoreTests, not a separate
P2P package or another test runner.

Run `swift test --filter WalletCoreTests` from the repository root.
[FilterSync adversaries](FilterSyncAdversaryTests.swift)
and [relay-store tests](TxBroadcasterStoreTests.swift)
cover important failure paths. [Core comparisons](../../DifferentialTests/README.md)
and retained [soak evidence](../../../docs/security/evidence/README.md) add different observations.
