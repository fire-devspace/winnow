# Winnow

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

**[Early access on TestFlight](https://testflight.apple.com/join/83djpNE7)** — mainnet by default; signet is one Advanced-mode toggle away. The official beta is planned for 0.9; see the [release roadmap](https://winnowwallet.com/#roadmap).

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Design papers, framed around the phone: [design-paper index](.github/internal/design-papers.md).
- **Taproot today.** Current receiving uses P2TR (BIP86), with no ECDSA signing path. The planned 0.7 P2WSH Safe is a separate, opt-in addition.
- **People and shared savings.** An address book of people, each with a public account key so every payment to them gets a fresh address, and savings held together as a Taproot k-of-n that no single key can spend: pick co-owners, choose how many must approve, ask for and give approvals as text. Cards carry public keys only.
- **Two modern multisig flavors.** MuSig2 (BIP327) n-of-n vaults and script-path k-of-n (`multi_a`, BIP387/388), coordinated over PSBTv2 (BIP370/371/373). Shared savings are the k-of-n form in plain words; Advanced mode shows the descriptors and PSBTs.
- **Silent Payments are planned.** Full BIP352 receiving is not in this release. The selected approach uses public tweak data served by compatible Bitcoin peers and matched locally, with no dedicated server, indexer fallback or full-chain download on the phone. Implementing and deploying that peer capability is part of the future work.
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
| **2.0** | **Work on the next BIP options** | Begin research and prototypes for P2MR migration and the peer capabilities needed for full Silent Payments. Production use depends on the relevant activation, implementation and deployment work. |

The **P2WSH Safe** uses `wsh(pk(KEY))` and transaction-bound ECDSA signatures. Hiding a fresh public key protects parked coins against slow quantum key recovery while that key stays private. Withdrawal reveals the key and still needs to confirm before an attacker can recover it; this is not full post-quantum signing. Discovery reuses ordinary BIP157/158 filters and does not depend on Silent Payments.

**P2MR ([BIP360](https://github.com/bitcoin/bips/blob/master/bip-0360.mediawiki))** is a draft consensus proposal. Mainnet use requires activation and wallet readiness; existing P2WSH Safes would migrate through an explicit, opt-in transaction. Merging a proposal does not activate it or upgrade existing outputs.

**Full Silent Payments ([BIP352](https://github.com/bitcoin/bips/blob/master/bip-0352.mediawiki))** is a payment-privacy workstream, separate from PQ authorization. Basic compact filters cannot supply the input-derived tweak points needed to generate candidate scripts. Peers must provide those records; the phone processes bounded windows and downloads matching blocks, including false positives. Missing peers or historical ranges leave incoming-payment checks incomplete and resumable, with no server or full-chain fallback. Ordinary wallet/Safe sync continues independently.

## Layout

The Bitcoin implementation lives in its own repository,
[btc-swift](https://github.com/winnowwallet/btc-swift) — keys to broadcast
with one dependency, plus the differential battery against
Bitcoin Core, the soak driver, and a scriptable CLI. This repository is the
wallet that wears it: the app pins the exact
[btc-swift 0.1.0 release](https://github.com/winnowwallet/btc-swift/releases/tag/v0.1.0)
and bumps library versions deliberately. Library and app releases are versioned independently.

Architecture invariant: **all logic lives in the library, where it is
tested; the app target is a thin shell.** No wallet, protocol, or crypto
logic may move into `WinnowApp` — if the UI needs something, expose it from
btc-swift.

- `Sources/WinnowApp` — the iOS app (SwiftUI, iOS 17+)
- `AppTests/` — app state, privacy, journal redaction, and integration suites
- `UITests/` — the simulator e2e against the signet fixture node
- `docs/` — public design papers, the security register, and the site
- `scripts/` — App Store Connect tooling and the TestFlight pipeline

## Build & test

```sh
scripts/install-xcodegen
xcodegen
open WinnowApp.xcodeproj
```

Build the `WinnowApp` scheme and run `WinnowAppTests` on an available iPhone simulator. Library builds and unit/protocol/vector tests belong in [winnowwallet/btc-swift](https://github.com/winnowwallet/btc-swift); this app repository has no root Swift package. The app's exact library release version is in [`project.yml`](project.yml).

The library also owns the three Keychain attribute tests, hosted in its own
minimal iOS test app, and publishes categorized LOC reports. App CI tests the
consumer integration; the manual node workflow runs only `WinnowAppUITests`.
App Store releases run the app unit suite once before signing and delivery.

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
against the same published library version as the app; the complete manual
journey is documented in the [story runbook](.github/internal/story-run.md).

Screenshot PNGs in `docs/screenshots/` are stored in Git LFS. After cloning,
install Git LFS and download the image objects before viewing or publishing them:

```sh
git lfs install --local
git lfs pull
```

The site and node-test workflows fetch LFS objects during checkout. Self-hosted
node-test runners need Git LFS installed. Capture tools continue writing PNGs
to the same paths; Git stores pointers when the files are added.

## License

Winnow is available under the [MIT License](LICENSE).
