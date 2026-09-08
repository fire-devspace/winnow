[Back to main README](../../../../README.md)

# Peer discovery and selection

The wallet needs reachable peers and a way to compare their answers.
Seed resolution, diversity rules, pooling, and peer persistence live together
here so discovery and admission follow one policy.

[PeerPool](PeerPool.swift) runs in one of two modes. Full service is the one
upstream's app uses: dial to `peerCount`, replace dead seats, serve header and
filter sync as well as relay. `enterRelayOnly(seats:)` is this fork's second
mode, for a wallet that is otherwise idle with a payment still going out — it
keeps a seat or two of what it already had, disconnects the rest, dials nothing
and resolves no addresses, cancels the replacement monitor, and refuses
`syncHeaders` (and so [FilterSync](../Filters/README.md)) with `relayOnly`.
`start()` restores full service and refills the seats; `stop()` is unchanged and
still disconnects everything. A relay-only session does not replace a seat it
loses: replacing one means dialling, which is the cost the session exists to
avoid. [TxBroadcaster](../Broadcast/README.md) is what usually drives it, so the
pool stops when there is nothing left to relay.

[FilterSync](../Filters/README.md) and
[AppModel](../../../WinnowApp/AppModel.swift) consume the pool.
Manual peers remain an Advanced setting; the app also uses DNS seeds and
a [generated fallback list](../Protocol/README.md).

[Peer policy tests](../../../../Tests/WalletCoreTests/Network/PeerPolicyTests.swift) cover
source classes, address ranges, persistence, and DNS replies.
[Pool tests](../../../../Tests/WalletCoreTests/Network/PeerPoolTests.swift) exercise
connection behavior. Diversity rules reduce concentration; they do not prove
that apparently different public peers have independent operators.
