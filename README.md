# Winnow

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

**[Early access on TestFlight](https://testflight.apple.com/join/83djpNE7)** — mainnet by default; signet is one Advanced-mode toggle away. The official beta is planned for 0.9; see the [release roadmap](https://winnowwallet.com/#roadmap).

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Design papers, framed around the phone: [design-paper index](.github/internal/design-papers.md).
- **Taproot today.** Current receiving uses P2TR (BIP86), with no ECDSA signing path. The planned 0.7 P2WSH Safe is a separate, opt-in addition.
- **People and shared savings.** An address book of people, each with a public account key so every payment to them gets a fresh address, and savings held together as a Taproot k-of-n that no single key can spend: pick co-owners, choose how many must approve, ask for and give approvals as text. Cards carry public keys only.
- **Two modern multisig flavors.** MuSig2 (BIP327) n-of-n vaults and script-path k-of-n (`multi_a`, BIP387/388), coordinated over PSBTv2 (BIP370/371/373). Shared savings are the k-of-n form in plain words; Advanced mode shows the descriptors and PSBTs.
- **One runtime dependency:** [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) (Bitcoin Core's libsecp256k1), pinned.
- **Warned explorer links** — choose mempool.space or a custom Esplora website; Winnow opens it only after a tap and privacy warning, never as a wallet backend.

## Release roadmap

These are planned milestones, not shipped features or promised dates. Release readiness sets the schedule. The [website roadmap](https://winnowwallet.com/#roadmap) follows the same sequence.

| Version | Milestone | Release scope |
| --- | --- | --- |
| **0.7** | **P2WSH Safe** | Add opt-in storage with fresh hidden public keys, private backup and restore, fresh change, exposure tracking, and a complete receive-and-withdraw flow using existing Bitcoin rules. |
| **0.8** | **Stabilization** | Exercise interrupted sync, stale backups, withdrawals, fee bumps and reorgs; fix regressions and measure bandwidth, memory and battery use on supported iPhones. |
| **0.9** | **Official beta** | Open a defined beta with documented recovery steps and known limitations, then validate everyday use through broader testing and feedback. |
| **1.0** | **Release after security review** | Address release-blocking findings, recheck fixes, and publish the review scope, results and remaining limitations. Security review determines readiness. |
| **2.0** | **Work on the next BIP options** | Begin research and prototypes for P2MR migration. Production use depends on the relevant activation, implementation and deployment work. |

The **P2WSH Safe** uses `wsh(pk(KEY))` and transaction-bound ECDSA signatures. Hiding a fresh public key protects parked coins against slow quantum key recovery while that key stays private. Withdrawal reveals the key and still needs to confirm before an attacker can recover it; this is not full post-quantum signing. Discovery reuses ordinary BIP157/158 filters.

**P2MR ([BIP360](https://github.com/bitcoin/bips/blob/master/bip-0360.mediawiki))** is a draft consensus proposal. Mainnet use requires activation and wallet readiness; existing P2WSH Safes would migrate through an explicit, opt-in transaction. Merging a proposal does not activate it or upgrade existing outputs.

## Layout

The app, Bitcoin implementation, CLI, fuzz harness, story tooling and website
live in this repository. The app and all development tools use one root
Swift package and dependency lockfile. There is one release version and one source revision.

Wallet, protocol and cryptographic logic stays in the library modules; the
SwiftUI app remains a thin shell. The root `Winnow` package groups `BitcoinCore`, `BitcoinP2P`, `WalletCore`
and `BlockchainBackend` for local use, plus the `btc-swift` development CLI
and `WinnowSoak`. The explorer backend is never instantiated by the wallet.

| Path | Purpose |
| --- | --- |
| `Sources/WinnowApp` | iOS app (SwiftUI, iOS 17+) |
| Other `Sources/` targets | Bitcoin libraries, offline CLI and soak driver |
| `Tests/` | BIP vectors, unit, loopback and Core differential tests |
| `Tests/NodeSupport` | Miner and RPC helpers shared by differential and UI tests |
| `AppTests/` | App state, privacy, journal redaction and iOS Keychain attributes |
| `UITests/` | Simulator journeys and storefront capture |
| `Tools/Fuzz/`, `Tools/Generate/`, `Tools/Story/` | Local development tools, outside the shipping app |
| `docs/` | Website, design papers and security evidence |
| `scripts/`, `infra/` | Build, release, reporting and dedicated test fixtures |

## Build & test

```sh
swift test
swift run btc-swift decode-tx <hex>
xcodegen
scripts/ci-app-tests /tmp/winnow-app-tests
scripts/ci-story
```

Use XcodeGen 2.46.0. `scripts/install-xcodegen` downloads and verifies that
version; locally it prints the executable path to use. The generated Xcode
project is ignored. Run app tests with a fresh results directory.
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

The resumable public-signet acceptance runner lives in [Tools/Story](Tools/Story/README.md).
Use `scripts/winnow-story` from this checkout. Its offline tests run in app CI
against the same local library as the app; the complete manual
journey is documented in the [story runbook](.github/internal/story-run.md).

Screenshot PNGs in `docs/screenshots/` are stored in Git LFS. After cloning,
install Git LFS and download the image objects before viewing or publishing them:

```sh
git lfs install --local
git lfs pull
```

The website workflow fetches LFS objects before publishing. The node workflow
writes new screenshots into its run artifacts. Capture tools continue writing PNGs
to the same paths; Git stores pointers when the files are added.

## License

Winnow is available under the [MIT License](LICENSE).
