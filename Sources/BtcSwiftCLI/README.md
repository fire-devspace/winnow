[Back to main README](../../README.md)

# Offline inspection CLI

The `btc-swift` executable exposes the wallet's parsers, address derivation, and
PSBT operations for debugging without opening the GUI. It uses the same
BitcoinCore and WalletCore code rather than implementing a second wallet.

[main.swift](main.swift) lists the commands. For example,
run `swift run btc-swift decode-tx <hex>` from the repository root.
It has no networking or persistent wallet store; its group-signing command is
a development aid, not the app's protected signing flow.

[CI](../../.github/workflows/ci.yml) smoke-tests release CLI derivation and key
aggregation. [Primitive tests](../../Tests/BitcoinCoreTests/README.md) and
[wallet tests](../../Tests/WalletCoreTests/README.md) cover the underlying behavior.
Not every CLI argument/error path has its own command-level test.
