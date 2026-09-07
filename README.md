# Winnow

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

**[Early access on TestFlight](https://testflight.apple.com/join/83djpNE7)** — mainnet by default; signet is one Advanced-mode toggle away. The official beta is planned for 0.9; see the [release roadmap](https://winnowwallet.com/roadmap).

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Design papers, framed around the phone: [design-paper index](.github/internal/design-papers.md).
- **Taproot today.** Current receiving uses P2TR (BIP86), with no ECDSA signing path. The planned 0.7 P2WSH Safe is a separate, opt-in addition.
- **People and shared savings.** An address book of people, each with a public account key so every payment to them gets a fresh address, and savings held together as a Taproot k-of-n that no single key can spend: pick co-owners, choose how many must approve, ask for and give approvals as text. Cards carry public keys only.
- **Two modern multisig flavors.** MuSig2 (BIP327) n-of-n vaults and script-path k-of-n (`multi_a`, BIP387/388), coordinated over PSBTv2 (BIP370/371/373). Shared savings are the k-of-n form in plain words; Advanced mode shows the descriptors and PSBTs.
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

The app owns the user flows. Wallet state and P2P networking share WalletCore;
BitcoinCore holds the cryptographic and descriptor primitives. The offline
btc-swift CLI, winnow-debug operator tool and fuzz harness use those same
implementations. Explorer links open an external website after a warning.

The [testing and feature policy](docs/testing.md) ties supported features to
actual app journeys and names the lower-level invariants worth keeping.
The homepage and [Advanced page](https://winnowwallet.com/advanced) are generated
from docs/journeys.json and the app test source; run scripts/build-site after
changing either. CI rejects missing or undocumented app scenarios.

| Path | Purpose |
| --- | --- |
| `Sources/WinnowApp` | iOS app (SwiftUI, iOS 17+) |
| Other `Sources/` targets | Bitcoin libraries and offline CLI |
| `Tests/` | BIP vectors, unit, loopback and Core differential tests |
| `Tests/Support` | `TestSupport`: fixtures, loopback harness, miner and RPC helpers shared by every test target |
| `AppTests/` | App state, privacy, journal redaction and iOS Keychain attributes |
| `UITests/` | Simulator journeys and their screenshots |
| `Tools/Fuzz/`, `Tools/Generate/`, `Tools/Debug/` | Local development tools, outside the shipping app |
| `docs/` | Website, design papers and security evidence |
| `scripts/`, `infra/` | Build, release, reporting and dedicated test fixtures |

## Build & test

```sh
swift test
swift run btc-swift decode-tx <hex>
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
network, your own peers, chain verification, the block explorer, fee bumping,
build details and the raw vault tools; a peer or setting you already have
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
