[Back to main README](../../../README.md)

# Wallet state and spending policy

Balances, coin selection, fees, recovery imports, people, and vault policies live
here. They supply the state and decisions behind receiving, sending, recovery,
and shared savings; the GUI should not carry a second wallet implementation.

[AppModel](../../WinnowApp/AppModel.swift) coordinates these rules with
WalletCore networking, [key storage](../Keys/README.md), and
[signing](../Transactions/README.md).
This directory groups related source inside WalletCore, not a separate service.

[WalletCore tests](../../../Tests/WalletCoreTests/README.md) cover balances, selection,
imports, shared spending, and reorg recovery. [App tests](../../../AppTests/README.md)
check persistence and protected actions; [UI journeys](../../../UITests/README.md)
check the complete user flow.
