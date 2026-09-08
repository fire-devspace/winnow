[Back to main README](../../../README.md)

# Wallet state and spending policy

Balances, coin selection, fees, recovery imports, people, and vault policies live
here. They supply the state and decisions behind receiving, sending, recovery,
and shared savings; the GUI should not carry a second wallet implementation.

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
