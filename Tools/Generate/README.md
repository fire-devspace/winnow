# Release-path generators

`winnow-debug generate` produces two constants the app ships and that `swift test`
cannot: the mainnet fallback-peer list (#161), which needs the live network,
and the mainnet header checkpoint (#89), which needs a 77 MB genesis-validated
header file. Both used to be test suites gated behind environment variables no
workflow set, so they never ran. `btc-swift` promises no network, so they do
not belong there either. These commands share the `winnow-debug` debugging
executable, outside the shipping app. Their sources live in
`Tools/Debug/Sources/WinnowDebug`; this directory retains the generator runbook.

Run from the repository root:

```sh
swift run winnow-debug generate --help
scripts/generate-fallback-peers
scripts/refresh-checkpoint ~/…/mainnet/headers.bin [height]
```

`fallback-peers` resolves the mainnet DNS seeds, dials candidates with the
same `PeerConnection` the app uses — whose handshake already refuses any peer
not advertising NODE_COMPACT_FILTERS — keeps one peer per /16 (the pool's own
`netblock` rule), drops peers more than `PeerPool.staleTipTolerance` behind
the median reported tip, and rewrites
`Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift`. The run fails
rather than shipping fewer than `--floor` peers. Generation is deliberately
not reproducible; keep the log as the release artifact.

`checkpoint` truncates a genesis-rooted `headers.bin` to the wanted height
and loads the copy through `HeaderChain` itself, so every header is
proof-of-work-checked by the code the app runs, then prints the constant as a
paste-ready literal for `NetworkParams.swift`. It then proves the shipped
claim in-process: a chain started from the derived checkpoint connects the
next 2,000 real headers and must reach the same tip, height and cumulative
work as the genesis-rooted chain; disagreement exits non-zero. `--vector-out`
writes those 2,000 headers, one per line as hex, which is how
`Tests/WalletCoreTests/Vectors/mainnet-headers-900001-902000.txt` is made and
how `HeaderChainTests` replays real headers past the checkpoint on every
CI run. Deriving the chainwork itself still needs the full file, so that part
remains release-time only.

The default output path is found from `#filePath`, so it lands in the
checkout the tool was built from whatever the working directory. Selection,
filtering and rendering are pure functions; `swift test` covers them offline
in `Tests/ToolsTests/GenerateTests.swift` alongside the library suites.
