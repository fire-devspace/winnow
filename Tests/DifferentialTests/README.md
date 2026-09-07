[Back to main README](../../README.md)

# Independent Bitcoin Core comparisons

These tests compare Winnow's descriptors, filters, transactions, and vault signing
with a real Bitcoin Core node. They check whether the same operations used by the
app produce results another implementation accepts.

[Node support](../Support/Node/README.md) owns the RPC and mining helpers.
[The node workflow](../../.github/workflows/node-tests.yml) creates a fresh local
signet, enables `WINNOW_DIFF=1`, runs this suite serially, and retains its log.
Use that workflow or its exact isolated-fixture setup when running locally.

An ordinary package run does not enable the gated node comparisons.
[HostProcessTests](HostProcessTests.swift) also exercise
the local subprocess helper. Passing node comparisons does not prove behavior
under every public-peer topology or replace [app journeys](../../UITests/README.md).
