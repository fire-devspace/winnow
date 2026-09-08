# Winnow

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

**[Early access on TestFlight](https://testflight.apple.com/join/83djpNE7)** — mainnet by default; signet is one Advanced-mode toggle away. The official beta is planned for 0.9; see the [release roadmap](https://winnowwallet.com/roadmap).

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Read [how it works](docs/architecture.html).
- **Taproot today.** Current receiving uses P2TR (BIP86), with no ECDSA signing path. The planned 0.7 P2WSH Safe is a separate, opt-in addition.
- **Pay people and share control.** Save a public payment card or Bitcoin address. From Wallet, create shared savings with a threshold such as 2-of-3: any two keys can spend while one is unavailable. A 1-of-n policy permits one key to spend. Cards carry public keys only.
- **Require another signing device.** Advanced mode offers MuSig2 accounts where every key must participate. The app journey uses an independent software signer and produces one Taproot key-path signature; desktop/hardware-wallet compatibility remains unverified. Compare the [two signing journeys and their limits](docs/vaults.html).
- **One runtime dependency:** [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) (Bitcoin Core's libsecp256k1), pinned.
- **Warned explorer links** — choose mempool.space or a custom Esplora website; Winnow opens it only after a tap and privacy warning, never as a wallet backend.

## Release roadmap

The [public roadmap](https://winnowwallet.com/roadmap) keeps planned work
separate from current features. Each milestone describes the user outcome,
the journeys that must pass, and unresolved work. Milestones are targets,
not shipped capabilities or promised dates.

## Layout

The app, Bitcoin implementation, CLI, fuzz harness, debugging tools and website
live in this repository. The app and all development tools use one root
Swift package and dependency lockfile. There is one release version and one source revision.

The app owns the user flows. WalletCore contains Bitcoin primitives, wallet
state, and P2P networking in one target. The winnow-debug tool and fuzz harness
use that same implementation. Explorer links open an external website after a warning.

The [testing and feature policy](docs/testing.md) ties supported features to
actual app journeys and names the lower-level invariants worth keeping.
The homepage and [Advanced page](https://winnowwallet.com/advanced) are generated
from docs/journeys.json and the app test source; run scripts/build-site after
changing either. CI rejects missing or undocumented app scenarios.

## Directory guides

Each guide explains what its directory owns, why the app or debugging needs it,
and which consumers and tests support that purpose. Every guide links back here.
When adding an owned directory with code, data, or documentation, add its README
and index link together. Parent folders with their own files need a guide too;
asset catalogs are documented by their owner, outside the bundle.

### App and Bitcoin rules

- App and inspection: [iPhone app](Sources/WinnowApp/README.md), [debugging and offline inspection](Tools/Debug/README.md).
- WalletCore primitives: [crypto/encodings](Sources/WalletCore/Crypto/README.md), [descriptors](Sources/WalletCore/Descriptors/README.md), [scripts](Sources/WalletCore/Script/README.md).
- WalletCore: [keys and secret storage](Sources/WalletCore/Keys/README.md), [PSBTs](Sources/WalletCore/PSBT/README.md), [transactions](Sources/WalletCore/Transactions/README.md), [wallet policy](Sources/WalletCore/Wallet/README.md).
- Network synchronization: [filters](Sources/WalletCore/Network/Filters/README.md), [headers](Sources/WalletCore/Network/Headers/README.md), [peer selection](Sources/WalletCore/Network/Peers/README.md).
- Network communication: [relay](Sources/WalletCore/Network/Broadcast/README.md), [mempool](Sources/WalletCore/Network/Mempool/README.md), [wire formats](Sources/WalletCore/Network/Protocol/README.md), [transport](Sources/WalletCore/Network/Transport/README.md).

### Tests and reference data

- User experience: [app decisions](AppTests/README.md), [GUI journeys](UITests/README.md).
- Rules and interoperability: [Bitcoin primitives](Tests/BitcoinCoreTests/README.md), [wallet rules](Tests/WalletCoreTests/README.md), [network cases](Tests/WalletCoreTests/Network/README.md), [Core comparisons](Tests/DifferentialTests/README.md).
- Shared fixtures: [TestSupport](Tests/Support/README.md), [real nodes](Tests/Support/Node/README.md), [controlled peers](Tests/Support/P2P/README.md).
- Reference data: [Bitcoin vectors](Tests/BitcoinCoreTests/Vectors/README.md), [MuSig2 vectors](Tests/BitcoinCoreTests/Vectors/bip327/README.md), [wallet/network vectors](Tests/WalletCoreTests/Vectors/README.md).
- Development tools: [tool tests](Tests/ToolsTests/README.md), [filter regressions](Tests/ToolsTests/Cases/filter/README.md), [PSBT regressions](Tests/ToolsTests/Cases/psbt/README.md).

### Debugging and fuzzing

- GUI/network debugging: [runbook](Tools/Debug/README.md), [implementation](Tools/Debug/Sources/WinnowDebug/README.md), [release-data generators](Tools/Generate/README.md).
- Fuzzing: [runbook](Tools/Fuzz/README.md), [executable](Tools/Fuzz/Sources/WinnowFuzz/README.md), [shared invariants](Tools/Fuzz/Sources/WinnowFuzzCore/README.md).

### Website and repository operations

- Website: [pages and generation](docs/README.md), [selected screenshots](docs/screenshots/README.md).
- Security: [reports and claims](docs/security/README.md), [retained soak evidence](docs/security/evidence/README.md).
- Operations: [public contributor runbooks](.github/internal/README.md), [workflows](.github/workflows/README.md), [scripts](scripts/README.md), [tooling regressions](scripts/tests/README.md).

## Build & test

```sh
swift test
swift run winnow-debug inspect tx <hex>
xcodegen
scripts/ci-app-tests /tmp/winnow-app-tests
scripts/ci-debug
```

Use XcodeGen 2.46.0. `scripts/install-xcodegen` downloads and verifies that
version; locally it prints the executable path to use. The generated Xcode
project is ignored. Run app tests with a fresh results directory.
Test fixtures live once, in the `TestSupport` library
([`Tests/Support`](Tests/Support/README.md)); it imports neither `Testing` nor
`XCTest`, so the swift-testing targets and the Xcode bundles share it and every
assertion stays at the call site.
`scripts/check-dependencies --xcode /path/to/DerivedData` verifies that Xcode uses the root
package and its committed third-party dependency revision.

[CI and release operations](.github/internal/ci-release.md) describes the shared
validation gates, node fixture, TestFlight recovery and website deployment.
The [LOC workflow](https://github.com/winnowwallet/winnow/actions/workflows/loc.yml) publishes JSON, CSV and
Markdown reports for every PR, main push and manual run, retained for 90 days
subject to organization limits. Its summary separates app/library/CLI source,
tests, webpages, tooling and other text; generated peers, binaries and LFS
pointers are excluded. See [the counting policy](scripts/report-loc.py).

Mainnet is the default network, and the app starts in beginner mode: Wallet,
Send, People, Settings. Turn on Advanced mode in Settings for the test
network, your own peers, chain verification, the block explorer, custom fees,
fee bumping, build details and the raw vault tools; a peer or setting you already have
stays visible until you remove it. Switch to signet there for development. Point the app at your own
filter-serving node (Settings → Manual peers); the node needs
`blockfilterindex=1` and `peerblockfilters=1`.

## Screenshots

GUI diagnostics live in [Tools/Debug](Tools/Debug/README.md). Use
`scripts/winnow-debug doctor` for environment checks and
`scripts/winnow-debug diagnostics` for local simulator logs and screenshots.
The demo and publication workflow has been retired; functional GUI journeys
remain in `UITests`.

Screenshot PNGs in `docs/screenshots/` are stored in Git LFS. After cloning,
install Git LFS and download the image objects before viewing or publishing them:

```sh
git lfs install --local
git lfs pull
```

The website workflow fetches LFS objects before publishing. The node workflow
writes new screenshots into its run artifacts. Local test runs use fresh temporary
directories. Select public images deliberately from a successful run; Git stores
LFS pointers when those selected PNGs are added.

## License

Winnow is available under the [MIT License](LICENSE).
