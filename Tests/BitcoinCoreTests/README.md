[Back to main README](../../README.md)

# Bitcoin primitive tests

Known-answer and adversarial tests protect the cryptographic, key-derivation,
descriptor, and script rules behind receiving, recovery, and shared signing.
They exercise WalletCore primitives directly so a wrong primitive is easier to locate
than through a complete app journey.

The [vectors](Vectors/README.md) provide independent
expected values; [TestSupport](../Support/README.md) supplies shared loaders.
The test target keeps its primitive-focused name; production has one WalletCore target.

Run `swift test --filter BitcoinCoreTests` from the repository root.
[CI](../../.github/workflows/ci.yml) runs the package suite on both architectures.
Passing vectors demonstrate agreement on their cases, not exhaustive correctness
or completion of an independent security review.
