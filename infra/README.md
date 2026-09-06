# Dedicated node integration

The monorepo's `node-tests.yml` runs the Core differential suite followed by
app simulator UI tests on one dedicated disposable custom signet. It is
available through confirmed manual dispatch and the Release workflow. Normal
PR checks are hosted and require no node.

The Winnow runner has labels `self-hosted, macOS, btc-swift, node-e2e` (the
existing `btc-swift` label is retained for runner compatibility). It needs
Swift, full Xcode with an iPhone simulator, and `bitcoin-cli`/`bitcoin-util`.
The workflow provisions only its own temporary fixture.

Each run starts its own node under `RUNNER_TEMP`, using loopback RPC 38600 and
P2P 38601 with cookie authentication, then stops it during cleanup. Occupied
ports fail before startup. No repository variables or pre-existing chain are
needed. A fresh chain keeps mempool, wallet state and mining difficulty
independent of earlier runs. Ordinary local development can still use
`scripts/signet-fixture up` with its default ports 38400/38401.

Both suites consume `Tests/NodeSupport`; the node workflow serializes them,
cleans up simulator miners after failures, and uploads logs, results and fresh
screenshots. Generated screenshots go to the artifact directory, leaving
committed website screenshots alone.

[Runner provisioning](runner/README.md) documents registering a replacement.
The optional `fixture/` Docker setup is for a separate host with explicit RPC
authentication; it is not the localhost/cookie layout used by the workflow.
