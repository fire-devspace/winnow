[Back to main README](../../../README.md)

# Controlled peers for network tests

LoopbackNode, FakeSocksProxy, and SyntheticChain construct local peers and
predictable blocks. They let wallet tests reproduce disconnects, malicious
responses, forks, and relay behavior without depending on public-network timing.

[Network tests](../../WalletCoreTests/Network/README.md) consume these helpers
through [TestSupport](../README.md). They return data and events;
the consuming test makes the assertion.

Run `swift test --filter WalletCoreTests` from the repository root.
[Adversarial filter tests](../../WalletCoreTests/Network/FilterSyncAdversaryTests.swift)
and [pool tests](../../WalletCoreTests/Network/PeerPoolTests.swift) exercise
controlled peer behavior. Loopback fixtures complement real-node and soak evidence;
they do not establish public-peer independence.
