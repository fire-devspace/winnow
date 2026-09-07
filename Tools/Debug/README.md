[Back to main README](../../README.md)

# GUI and network debugging

`winnow-debug` contains only environment checks, local simulator diagnostics,
release-data generators, and the sustained network-read soak. The offline
`btc-swift` CLI and `WinnowFuzz` sanitizer harness remain separate.

Run from the checkout (the wrapper also works from another directory):

```sh
scripts/winnow-debug doctor
scripts/winnow-debug diagnostics --simulator booted --out /tmp/winnow-diagnostics
scripts/winnow-debug diagnostics --simulator DEVICE_UUID --out /tmp/winnow-diagnostics --run E2E_RUN_ID
scripts/winnow-debug generate --help
scripts/winnow-debug soak --help
scripts/winnow-debug soak --network signet --minutes 30 --out /tmp/signet-soak.jsonl
```

`doctor` checks the app project, Swift, Xcode, simulator tooling and Git.
`diagnostics` saves a screenshot and the last ten minutes of app logs. With an
explicit E2E run ID, it also copies that run's redacted event journal and
signet peer list, when present. It does not copy wallets or Keychain material.
These are local debugging files, with no publishing or media-review workflow.

The [generator runbook](../Generate/README.md) documents fallback-peer and
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
