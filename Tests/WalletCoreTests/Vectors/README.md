[Back to main README](../../../README.md)

# Wallet and network reference data

These fixtures provide BIP158 filters, BIP341 signing examples, controlled DNS
replies, and real mainnet and signet headers. They give wallet/network tests
stable inputs without querying a changing public service during each run.

[SighashBIP341Tests](../SighashBIP341Tests.swift),
[PeerPolicyTests](../Network/PeerPolicyTests.swift), and
[HeaderChainTests](../Network/HeaderChainTests.swift) are consumers.
SwiftPM copies the directory into the test resource bundle.

Refresh Bitcoin vectors from their named specifications and record the source
revision; DNS JSON files are deliberately controlled response fixtures.
The two 2,000-header files, one per network that ships a checkpoint, are
produced by the [checkpoint generator](../../../Tools/Generate/README.md)
from a genesis-validated header file. Preserve that provenance and run
`swift test --filter WalletCoreTests`; do not replace expected data just to make tests pass.
