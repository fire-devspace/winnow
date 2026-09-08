[Back to main README](../../README.md)

# Tests for debugging and fuzz tools

This suite checks the development tools that diagnose the GUI, refresh network
constants, observe long-running scans, and replay parser failures. These tools
need tests because their output informs debugging and release decisions.

It consumes the shared [debugging implementation](../../Tools/Debug/Sources/WinnowDebug/README.md)
and [fuzz invariants](../../Tools/Fuzz/Sources/WinnowFuzzCore/README.md).
[GenerateTests](GenerateTests.swift) exercise offline generation
decisions; [FallbackPeerAgeTests](FallbackPeerAgeTests.swift) exercise the
freshness rule for the generated peer list against supplied clocks;
[OperatorCLITests](OperatorCLITests.swift) check command behavior.

Run `swift test --filter ToolsTests` from the repository root.
[FuzzRegressionTests](FuzzRegressionTests.swift) discover only
`Cases/<target>/*.bin`; READMEs are not replay inputs. Real-network observations
and the generator's live inputs remain separate from these deterministic tests.
