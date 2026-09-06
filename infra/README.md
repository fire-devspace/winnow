# Dedicated node integration

The monorepo's `node-tests.yml` runs the Core differential suite and the app
simulator UI tests on one dedicated disposable custom signet per run. The
differential leg runs on pull requests from branches in this repository that
touch code, on every push to `main`, nightly, on release and on confirmed
manual dispatch; the UI leg runs nightly, on release and on confirmed manual
dispatch, and a `capture_storefront` input adds the App Store screenshot set.
Forks never reach the self-hosted seat. Hosted PR checks need no node.

The seat itself (one macOS VM, its listeners and its signet nodes) is
inventoried in the `macos-ci-runners` repository README under "Current
inventory".

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

Both suites consume `Tests/NodeSupport`. One listener per VM keeps jobs on the
seat serial, the workflow sweeps a fixture left by an interrupted run before
starting its own, cleans up simulator miners after failures, and uploads logs,
results and fresh screenshots. Generated screenshots go to the artifact directory, leaving
committed website screenshots alone.

[Runner provisioning](runner/README.md) documents registering a replacement.
The optional `fixture/` Docker setup is for a separate host with explicit RPC
authentication; it is not the localhost/cookie layout used by the workflow.
