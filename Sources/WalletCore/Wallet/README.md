[Back to main README](../../../README.md)

# Wallet state and spending policy

Balances, coin selection, fees, recovery imports, people, and vault policies live
here. They supply the state and decisions behind receiving, sending, recovery,
and shared savings; the GUI should not carry a second wallet implementation.

A `HistoryEntry` for a transaction this wallet built records where its outputs
went — the scripts and amounts it paid, and which of its own outputs were
change — when [Wallet](Wallet.swift) commits the send, and keeps that record
through confirmation. The pending record holding the same facts is retired by
the block that includes the transaction, so without this a confirmed payment
could say how much left and never to whom. An entry with no breakdown is one
this wallet did not build, or one written before the breakdown existed: absent
means not known, not that the transaction paid nobody.

[FeePolicy](FeePolicy.swift) resolves the feerate a send is priced at: an explicit
user override first, then an optional estimate the embedder supplies (this fork
adds that parameter for Fire's own fee gateway; upstream has no estimator, the
parameter defaults to nil, and nothing here fetches one), then the median of the
feerates this wallet has itself paid and seen confirm, then a static preset. An
estimate is never taken below that median, and the peers' `feefilter` floor still
clamps the result from below. Every supplied number, override and estimate and
sample and floor alike, is used only when it is finite and inside
`(0, FeePolicy.maximumSatPerVByte]`; anything else is discarded rather than
clamped, so resolution cannot hand [CoinSelection](CoinSelection.swift) a rate its
own argument contract would refuse.

**The peer floor is treated as hostile input, which is a fork-local policy.** A
BIP133 `feefilter` is an unvalidated number a peer sends about its own mempool,
and the pool seats whoever answers, so this fork aggregates it as the **median**
of connected peers rather than upstream's maximum, and caps how far it may lift
a send at `FeePolicy.maximumPeerFloorSatPerVByte` — ten times the high preset,
the most expensive rate this wallet chooses on its own. Uncaught, the maximum let
a single seated peer advertising 10,000,000 sat/kvB price every send at 10,000
sat/vB, which `usable` accepts because it is the top of the band the selector
allows: the user overpays miners by three orders of magnitude on one stranger's
word. The median needs most of the pool to agree before the floor moves, and the
cap bounds what even a unanimous pool can ask for. Neither touches the wallet's
own numbers — an override or an observed median above the cap is paid in full;
only the lift from a stranger's advertised minimum is bounded. The honest cost is
a peer stricter than its neighbours: a send priced at the median may not relay
through that one peer, and `TxBroadcaster` already reports that per peer as
`feeFloorExceeded`.

[AppModel](../../WinnowApp/AppModel.swift) coordinates these rules with
WalletCore networking, [key storage](../Keys/README.md), and
[signing](../Transactions/README.md).
VaultRecord is shared by app persistence and the optional accounts in a wallet
backup, so there is one representation to restore. Signing keys and live
MuSig2 nonce sessions are not part of an account record.

[WalletCore tests](../../../Tests/WalletCoreTests/README.md) cover balances, selection,
imports, shared spending, and reorg recovery. [App tests](../../../AppTests/README.md)
check persistence and protected actions; [UI journeys](../../../UITests/README.md)
check the complete user flow.
