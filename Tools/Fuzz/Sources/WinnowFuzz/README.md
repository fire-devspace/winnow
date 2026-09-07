[Back to main README](../../../../README.md)

# Fuzz execution and reproduction

The WinnowFuzz executable chooses seeded inputs, invokes the shared invariants,
and writes logs and reproducer artifacts. It supports deterministic CI smoke
runs and longer sanitizer runs without becoming part of the wallet app.

[The fuzz runbook](../../README.md) documents commands, seeds, input
limits, and reproduction. [WinnowFuzzCore](../WinnowFuzzCore/README.md)
owns the invariants, so the executable and regression tests exercise the same rules.

[CI](../../../../.github/workflows/ci.yml) runs a fixed seed;
[the sanitizer workflow](../../../../.github/workflows/fuzz.yml) runs longer campaigns.
[Saved regressions](../../../../Tests/ToolsTests/README.md) preserve investigated findings.
A finite campaign samples inputs; its success does not prove all parsers correct.
