# v1 launch handoff

Status recorded 2026-08-17. This is a handoff checkpoint, not authorization to spend bitcoin, switch the default network, tag v1.0.0, upload assets, or submit the app.

## Ready for review

- PR #36 prevents stale simulators and `WinnowAppUITests-Runner` processes from surviving the UI leg on a self-hosted runner. Local package tests passed, and a controlled dummy-runner probe verified both cleanup actions.
- PR #37 adds bundle v2 recovery metadata for silent-payment UTXOs, keeps v1 imports readable, and refuses incomplete watch-only export when silent-payment funds are present. Package tests passed (263 tests), the simulator build succeeded, and recovery is covered through independent Schnorr verification.
- The 2026-08-17 iPhone 17 Pro Max signet run passed all 10 UI tests and produced 1320 × 2868 screenshots. The App Store-safe candidate subset and exclusions are in `app-store-screenshots.md`.
- The uncontended UI mining sample completed 102 tip wins with zero lost races. That supports the existing low-contention observation for #28; it does not measure the deliberately contended probability needed to close that issue.

## External CI blocker

Both PRs depend on the same node-backed check. The runner reaches the signet node, but GitHub's `BTC_SWIFT_RPC_COOKIE` contains a cookie invalidated by the node restart. Local RPC with the node's current cookie succeeds, and the existing `miner` wallet was loaded before the successful UI run. No credential is stored in this repository.

Owner action for #14:

1. On `alexs-mac-mini`, generate a dedicated fixed `rpcauth` username/password and add the generated `rpcauth=` line to `~/.bitcoin-mysignet/bitcoin.conf`.
2. Restart the node and run `loadwallet miner` once.
3. Store the matching `username:password` value in the repository secret `BTC_SWIFT_RPC_COOKIE`.
4. Rerun the failed node-backed checks on PRs #36 and #37; merge only after they pass.

Do not paste the live cookie into an issue, pull request, log, or tracked file. A fixed credential should be dedicated to CI and rotated if exposed.

## Owner-gated launch sequence

1. Merge #36 and #37 after green node-backed checks.
2. Perform #8 exactly as written with a deliberately small real-mainnet amount and retain the launch recording. This is the only step here that spends real bitcoin.
3. If #8 passes, implement #9: make mainnet the default, recheck fee presets and peer diversity, and update onboarding copy.
4. Recapture the selected 6.9-inch screenshots after #9, confirm that no mnemonic or development endpoint is visible, then upload them for #6.
5. Verify full Xcode execution on the intended self-hosted CI runner for #11. Keep #28 open until a deliberately contended mining sample sizes the retry bound.
6. Only after every gate is green: tag v1.0.0, archive, upload, and submit.
