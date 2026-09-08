[Back to main README](../../README.md)

# Release-path generators

`winnow-debug generate` produces the constants the app ships and that `swift test`
cannot: the mainnet fallback-peer list (#161), which needs the live network,
and a network's header checkpoint (#89), which needs a genesis-validated header
file for that network — 77 MB for mainnet, 24 MB for signet. Both used to be
test suites gated behind environment variables no workflow set, so they never
ran. These commands share the `winnow-debug` debugging executable, outside the
shipping app. Their sources live in `Tools/Debug/Sources/WinnowDebug`; this
directory retains the generator runbook.

Run from the repository root:

```sh
swift run winnow-debug generate --help
scripts/generate-fallback-peers
scripts/check-fallback-peer-age [--as-of ISO8601] [--in PATH]
scripts/refresh-checkpoint [--network mainnet|signet] ~/…/headers.bin [height]
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
`Tests/WalletCoreTests/Vectors/mainnet-headers-900001-902000.txt` and
`signet-headers-300001-302000.txt` are made and how `HeaderChainTests` replays
real headers past each checkpoint on every CI run. Deriving the chainwork
itself still needs the full file, so that part remains release-time only.

`--network` chooses which constant is derived, and the script follows it for
the shipped height it compares against and the vector it writes. There is
deliberately one derivation rather than one per network: a second copy is how
two networks end up with two definitions of the same constant. A genesis-rooted
header file for a network is whatever this code wrote by syncing it —
`winnow-debug soak --network NET --state DIR` leaves one behind, and a
simulator container holds one too. The signet constant currently in the tree
was derived on a machine with no route to port 38333; `NetworkParams.swift`
records where its header file came from instead, and what that provenance is
and is not worth.

`check-fallback-peer-age` answers the other half of the same question and
needs no network: is the committed list still within
`NetworkParams.maxFallbackPeerAgeDays`. `scripts/check-release-policy` asks it
at a release tag, from a runner with no Swift toolchain; this asks it on any
cadence, from any lane, and exits non-zero when the list is too old, records no
generation date, or records one in the future. Both read the ceiling from the
library rather than carrying a copy, and `--as-of` fixes the clock so the rule
is testable rather than only observable. A consumer that pins a revision
instead of following tags reaches neither gate by itself and should run this
one on its own schedule: the bundled list ages from the day it pinned, and the
always-on shape tests pass just as happily on a list three months stale.

The default output path is found from `#filePath`, so it lands in the
checkout the tool was built from whatever the working directory. Selection,
filtering and rendering are pure functions; `swift test` covers them offline
in `Tests/ToolsTests/GenerateTests.swift` alongside the library suites.
