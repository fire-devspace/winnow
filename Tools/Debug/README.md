[Back to main README](../../README.md)

# GUI and network debugging

`winnow-debug` is the single debugging executable: offline transaction, PSBT,
and descriptor inspection, environment checks, simulator diagnostics, release-data
generation, and network soaks. It uses the same WalletCore as the app.
The `WinnowFuzz` sanitizer harness remains a separate test driver.

Run from the checkout (the wrapper also works from another directory):

```sh
scripts/winnow-debug inspect tx <hex>
scripts/winnow-debug inspect psbt <base64>
scripts/winnow-debug inspect descriptor '<descriptor>' mainnet
scripts/winnow-debug doctor
scripts/winnow-debug diagnostics --simulator booted --out /tmp/winnow-diagnostics
scripts/winnow-debug diagnostics --simulator DEVICE_UUID --out /tmp/winnow-diagnostics --run E2E_RUN_ID
scripts/winnow-debug generate --help
scripts/winnow-debug check fallback-peers [--in PATH] [--as-of ISO8601]
scripts/winnow-debug soak --help
scripts/winnow-debug soak --network signet --minutes 30 --out /tmp/signet-soak.jsonl
```

`inspect` is offline and read-only. Descriptor inspection derives index zero
for each multipath choice; omit the network argument to use signet. The old
standalone CLI's signing, combination, finalization, filter matching, and key
aggregation commands are removed. The app's signing and filter paths retain
their own primitive, adversarial, and GUI tests.

`doctor` checks the app project, Swift, Xcode, simulator tooling and Git.
`diagnostics` saves a screenshot and the last ten minutes of app logs. With an
explicit E2E run ID, it also copies that run's redacted event journal and
signet peer list, when present. It does not copy wallets or Keychain material.
These are local debugging files, with no publishing or media-review workflow.

`check` reads generated release data and reports on it without writing
anything: today its one subject is the bundled fallback-peer list, whose age it
compares with `NetworkParams.maxFallbackPeerAgeDays` and answers in its exit
status. `scripts/check-fallback-peer-age` is the same command by a shorter
name. The [generator runbook](../Generate/README.md) documents fallback-peer and
checkpoint refreshes. The soak preserves its JSONL metrics and optional
header/filter/peer state, defaults to public signet and three peers, and takes
one sample per minute. `--minutes 0` or omission runs until interrupted.
Help performs no network work; invalid soak options retain exit status 2.

`ToolsTests` covers the generator decisions, command dispatch, soak options,
diagnostics arguments, subprocess output handling and fuzz regressions.
`scripts/ci-debug` exercises the wrapper from outside the checkout; CI also
smoke-tests generator and soak help in the release binary.

## Removed commands

The demo/story runner, scripted personas, companion signing, resumable story
checkpoints, recording, media approval, and publication commands are removed.
Existing private `.build/winnow-story/` data is left on disk; the debugging
commands neither read nor migrate it. Historical evidence remains historical.

| Previous executable | Current command |
| --- | --- |
| `winnow-generate` | `winnow-debug generate` |
| `WinnowSoak` | `winnow-debug soak` |
| `winnow-story doctor` | `winnow-debug doctor` |

The [implementation guide](Sources/WinnowDebug/README.md) links the command
implementation to its consuming tests and CI checks.
