[Back to main README](../../../../README.md)

# Payment relay

TxBroadcaster announces signed payments, handles peer fee filters and retry
state, and retains enough history to relay a payment again after a chain reorg.
The app needs this to distinguish a signed payment from one actually announced.

`enterRelayOnly(seats:)` is this fork's answer to a wallet going idle with a
payment in flight: it narrows the [peer pool](../Peers/README.md) to a
relay-only session, announcements and rebroadcasts carry on over the seats that
remain, and the pool stops itself as soon as this broadcaster has nothing
unconfirmed left — a confirmation, a cancellation or a replacement all reach it
through the same reschedule. Nothing external has to watch for that drain, and
nothing else changes: the peers are the same peers, and stopping the pool
outright still means the payment is not relayed until the app is opened again.

[AppModel](../../../WinnowApp/AppModel.swift) coordinates relay with the
wallet and [mempool observations](../Mempool/README.md).
This is one part of WalletCore networking, not a separate backend.

[Relay tests](../../../../Tests/WalletCoreTests/Network/TxBroadcasterTests.swift) exercise
announcements and retry policy. [Store tests](../../../../Tests/WalletCoreTests/Network/TxBroadcasterStoreTests.swift)
cover damaged persistence and reorg recovery. [App journeys](../../../../UITests/README.md)
check the resulting payment history against a node.
