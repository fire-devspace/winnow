[Back to main README](../../../../README.md)

# Unconfirmed payment observations

MempoolWindow opens a bounded full-relay subscription while the app needs
unconfirmed payment information. It observes incoming payments and peer echoes
of outgoing transactions without introducing a wallet server.

[AppModel](../../../WinnowApp/AppModel.swift) connects these observations to
Receive and Send; [TxBroadcaster](../Broadcast/README.md)
owns outgoing announcements. An observation is not a block confirmation.

[MempoolWindow tests](../../../../Tests/WalletCoreTests/Network/MempoolWindowTests.swift)
exercise watched outputs, duplicate announcements, missing transactions, buffer
bounds, and shutdown. [UI journeys](../../../../UITests/README.md) check the unconfirmed
state visible to a person.
