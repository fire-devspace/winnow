[Back to main README](../../../../README.md)

# Bitcoin wire formats and network parameters

Messages, framing, blocks, transactions, peer addresses, and network constants
provide the byte formats shared by wallet networking, signing, and debugging.
Keeping these in WalletCore avoids a separate P2P package boundary.

[Transport](../Transport/README.md),
[scanning](../Filters/README.md), and
[transaction construction](../../Transactions/README.md) use them.
[Wire tests](../../../../Tests/WalletCoreTests/Network/WireTests.swift),
[transaction tests](../../../../Tests/WalletCoreTests/Network/TransactionTests.swift), and
[network-parameter tests](../../../../Tests/WalletCoreTests/Network/NetworkParamsTests.swift)
cover encoding, parsing, and network selection.

FallbackPeersGenerated.swift is produced by the
[release-data generator](../../../../Tools/Generate/README.md). Refresh it through that
tool and retain its log; do not hand-edit a list merely to pass the freshness gate.
