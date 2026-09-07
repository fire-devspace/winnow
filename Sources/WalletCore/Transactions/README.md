[Back to main README](../../../README.md)

# Constructing and signing payments

Address decoding, transaction construction, Taproot signature hashes, and signing
turn a reviewed payment into Bitcoin transaction bytes. These rules are shared
by ordinary sends, fee replacement, and vault spending.

[Wallet state](../Wallet/README.md) supplies coins and policy;
[the app](../../WinnowApp/README.md) owns review and authorization.
[PSBTs](../PSBT/README.md) carry work that needs another signer.

[Builder tests](../../../Tests/WalletCoreTests/TransactionBuilderTests.swift),
[signer tests](../../../Tests/WalletCoreTests/SignerTests.swift), and
[sighash tests](../../../Tests/WalletCoreTests/SighashBIP341Tests.swift) check the rules.
[Send-preview tests](../../../AppTests/SendPreviewTests.swift) protect the app boundary,
and [Core comparisons](../../../Tests/DifferentialTests/TransactionAndPSBTDiffTests.swift)
check independently accepted transaction behavior.
