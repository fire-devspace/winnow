[Back to main README](../../../README.md)

# Descriptors and shared signing

Descriptors turn public key expressions into the addresses and spending policies
used by wallet imports and shared savings. MuSig key aggregation and MuSig2
sessions support the advanced jointly signed vault flow.

The [wallet and vault code](../Wallet/README.md) and
[offline inspector](../../../Tools/Debug/README.md) consume this WalletCore code.
It describes policies and signing operations; it does not own app state or peers.

[Descriptor tests](../../../Tests/BitcoinCoreTests/DescriptorTests.swift),
[parser bounds](../../../Tests/BitcoinCoreTests/DescriptorBoundsTests.swift), and
[MuSig2 tests](../../../Tests/BitcoinCoreTests/MuSig2Tests.swift) cover derivation,
malformed input, known answers, and session safety. [Core comparisons](../../../Tests/DifferentialTests/DescriptorDiffTests.swift)
check agreement with an independent implementation.
