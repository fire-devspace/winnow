[Back to main README](../../../README.md)

# Real-node test helpers

BitcoinCLI, HostProcess, and SignetMiner let tests query a node and mine blocks
on the disposable custom signet. Differential and GUI tests need the same
transactions and chain operations, so these helpers are shared once.

Consumers are [Core comparisons](../../DifferentialTests/README.md) and
[app journeys](../../../UITests/README.md). They live in the framework-agnostic
[TestSupport library](../README.md); assertions belong to callers.

[HostProcess tests](../../DifferentialTests/HostProcessTests.swift) cover
subprocess behavior. [Node CI](../../../.github/workflows/node-tests.yml) exercises
the RPC/miner path against its own temporary node. This directory does not
provision TDX machines or register runners.
