[Back to main README](../../../README.md)

# Recovery and address keys

BIP39 recovery words, BIP32 key derivation, and BIP86 Taproot addresses live here.
They let the same recovery phrase recreate a wallet and derive receiving and
change addresses consistently.

The [wallet](../../WalletCore/Wallet/README.md),
[transaction signer](../../WalletCore/Transactions/README.md), and
[app](../../WinnowApp/README.md) use these BitcoinCore primitives.
Persistent secret storage belongs to [WalletCore keys](../../WalletCore/Keys/README.md).

[BIP39](../../../Tests/BitcoinCoreTests/BIP39Tests.swift),
[BIP32](../../../Tests/BitcoinCoreTests/BIP32Tests.swift), and
[BIP86](../../../Tests/BitcoinCoreTests/BIP86Tests.swift) tests use known-answer vectors.
The embedded English word list is protocol data; changes must preserve the
standard word ordering and pass the recovery vectors.
