[Back to main README](../../../../README.md)

# Compact-filter parser regressions

These three binary inputs retain noncanonical CompactSize encodings of zero
using two-, four-, and eight-byte payloads. They keep previously problematic
filter parsing cases in the ordinary regression run.

[FuzzRegressionTests](../../FuzzRegressionTests.swift) discovers the
`.bin` files and passes them to the same
[filter invariant](../../../../Tools/Fuzz/Sources/WinnowFuzzCore/README.md) used by the harness.

The [fuzz runbook](../../../../Tools/Fuzz/README.md) records the corpus's migration origin
and explains how to retain a new finding. Add the exact failing bytes from an
investigated result; do not regenerate existing inputs during tests.
Run `swift test --filter FuzzRegressionTests` from the repository root.
