[Back to main README](../README.md)

# Build, test, and debugging entry points

These scripts connect the repository's code to Xcode, SwiftPM, disposable test
nodes, the website, reporting, and release tooling. They provide shared commands
for contributors and CI without duplicating the wallet implementation.

[The workflows](../.github/workflows/README.md) are their primary automated
consumers. [CI/release operations](../.github/internal/ci-release.md) and
[debugging](../Tools/Debug/README.md) explain how to use them.
signet-fixture starts test nodes; runner machines and registration are managed privately.

[ci-required](ci-required) selects checks from changed inputs and reuses successful
PR evidence for an identical main tree. Its Linux selection job links the prior
run; missing or uncertain evidence runs fresh checks.

[Python regressions](tests/README.md) cover CI selection, site generation and LOC
reporting. The existing CI jobs exercise build, dependency, warning, debugging,
and release-exclusion checks. Signing/submission commands have external effects;
their workflow runbooks identify when they are used.
Run commands from the repository root unless their help specifies otherwise.
