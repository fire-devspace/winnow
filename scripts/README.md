[Back to main README](../README.md)

# Build, test, and debugging entry points

These scripts connect the repository's code to Xcode, SwiftPM, disposable test
nodes, the website, reporting, and release tooling. They provide shared commands
for contributors and CI without duplicating the wallet implementation.

[The workflows](../.github/workflows/README.md) are their primary automated
consumers. [CI/release operations](../.github/internal/ci-release.md) and
[debugging](../Tools/Debug/README.md) explain how to use them.
signet-fixture starts test nodes; runner machines and registration are managed privately.
check-fallback-peer-age reports whether the bundled peer list is still current,
outside the release path that normally asks for it.

[Python regressions](tests/README.md) cover site generation and LOC
reporting. The existing CI jobs exercise build, dependency, warning, debugging,
and release-exclusion checks. Signing/submission commands have external effects;
their workflow runbooks identify when they are used.
Run commands from the repository root unless their help specifies otherwise.
