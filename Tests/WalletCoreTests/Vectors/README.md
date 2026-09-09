[Back to main README](../../../README.md)

# Wallet and network reference data

These fixtures provide BIP158 filters, BIP341 signing examples, controlled DNS
replies, and real mainnet headers. They give wallet/network tests stable inputs
without querying a changing public service during each run.

[SighashBIP341Tests](../SighashBIP341Tests.swift),
[PeerPolicyTests](../Network/PeerPolicyTests.swift), and
[HeaderChainTests](../Network/HeaderChainTests.swift) are consumers.
SwiftPM copies the directory into the test resource bundle.

`difficulty-boundaries.json` holds the period-start, previous, and adjustment
headers for mainnet heights 32,256 and 901,152. Retrieved on 2026-09-09 through
[Blockstream's block API](https://github.com/Blockstream/esplora/blob/master/API.md#blocks):
resolve each height with `/block-height/:height`, then fetch `/block/:hash/header`.
Each serialized header's double-SHA256 was checked against its returned block hash.
[HeaderDifficultyTests](../Network/HeaderDifficultyTests.swift) checks proof of work,
the adjacent headers' linkage, and the calculated adjustment. Its fixed Core
calculation vectors come from [Bitcoin Core v31.0 pow_tests.cpp](https://github.com/bitcoin/bitcoin/blob/v31.0/src/test/pow_tests.cpp).

Refresh Bitcoin vectors from their named specifications and record the source
revision; DNS JSON files are deliberately controlled response fixtures.
The 2,000-header file is produced by the [checkpoint generator](../../../Tools/Generate/README.md)
from a genesis-validated header file. Preserve that provenance and run
`swift test --filter WalletCoreTests`; do not replace expected data just to make tests pass.
