[Back to main README](../../../../README.md)

# Peer connections

PeerConnection owns the asynchronous connection to a Bitcoin peer, including
handshake and message exchange. Scanning and payment relay need this shared
transport instead of separate connections implemented by each feature.

[Peer pooling](../Peers/README.md),
[filter scanning](../Filters/README.md), and
[mempool windows](../Mempool/README.md) consume it.
Wire types live in [Protocol](../Protocol/README.md).

[FilterSync handshake tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift),
[peer-pool tests](../../../../Tests/WalletCoreTests/Network/PeerPoolTests.swift), and
[wire tests](../../../../Tests/WalletCoreTests/Network/WireTests.swift) exercise it through
controlled peers. Real-network soak evidence adds observations beyond loopback tests.
