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
and the pool seats whoever answers, so this fork aggregates it as the **lower
median over the pool's seats** (`FeePolicy.seatMajorityFloor`), every seat that
has sent no filter counting as 0, rather than upstream's maximum, and caps how
far it may lift a send at `FeePolicy.maximumPeerFloorSatPerVByte` — ten times the
high preset, the most expensive rate this wallet chooses on its own. Uncaught,
the maximum let a single seated peer advertising 10,000,000 sat/kvB price every
send at 10,000 sat/vB, which `usable` accepts because it is the top of the band
the selector allows: the user overpays miners by three orders of magnitude on
one stranger's word. A median of only the peers that had spoken was the same
handover by another route: the first filter into a pool of three was the median
of one, and a second honest filter only averaged the liar down by half. Counted
over seats with silence as 0, the floor moves only when a strict majority of the
seats name a number at or above it, it is always a number some peer actually
sent, and the cap bounds what even a unanimous pool can ask for. Neither touches
the wallet's own numbers — an override or an observed median above the cap is
paid in full; only the lift from a stranger's advertised minimum is bounded.

What the cap cannot do is tell an honest floor above it from a lie, and both
costs are real. A mempool that has genuinely settled above 120 sat/vB and a
majority of seats agreeing to say so arrive as the same unvalidated number, and
both are priced at the cap, which is a send that does not relay: `broadcast`
returns a txid, no peer takes the bytes, and `Wallet.commit` has already marked
the inputs spent. The cap stays, because refusing the send instead would let one
lying majority stop this wallet spending at all, and `FeePolicy.resolution`
returns the clamped floor beside the rate so the caller, which is the side that
knows whether the money can wait, can refuse to build, or show both numbers and
let the person spending pay the floor with an override, which is not capped.

The other honest cost is a peer stricter than its neighbours: a send priced at
the majority's floor may not relay through that one peer. Nothing names it.
`TxBroadcaster` skips a peer whose filter refuses the rate rather than
announcing into it, so what shows the loss is the peer count in `.announced`
coming back short of the seats; `.feeFloorExceeded` is the pool-wide signal,
raised when the lowest filter among the connected peers is above the rate and no
peer is left to relay at all.

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
