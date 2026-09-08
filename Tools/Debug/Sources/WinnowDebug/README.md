[Back to main README](../../../../README.md)

# Debugging implementation

This executable implements offline transaction/PSBT/descriptor inspection, environment checks, simulator diagnostics, network
soaks, and generation of the app's fallback peers and header checkpoint, plus
the freshness check that reads the generated peer list back.
It helps investigate the actual GUI and networking code while staying outside
the shipping app.

[The debug runbook](../../README.md) is the command reference;
[the generator runbook](../../../Generate/README.md) explains live-data provenance.
Both the wrapper and `swift run winnow-debug` use this implementation.

[ToolsTests](../../../../Tests/ToolsTests/README.md) checks command dispatch, subprocesses,
generator policy, inspection results and invalid inputs, and soak options. [ci-debug](../../../../scripts/ci-debug) exercises the
wrapper from outside the checkout. A soak log records observations, not a blanket
readiness verdict; diagnostics do not publish or upload their captures.
