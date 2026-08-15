# btc-swift

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Design papers, framed around the phone: [docs/](docs/README.md).
- **Taproot only.** P2TR receiving (BIP86); no legacy address types, no ECDSA signing paths.
- **Two modern multisig flavors.** MuSig2 (BIP327) n-of-n vaults and script-path k-of-n (`multi_a`, BIP387/388), coordinated over PSBTv2 (BIP370/371/373).
- **Silent payments, send-side** (BIP352): pay reusable `sp1…` codes.
- **One runtime dependency:** [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) (Bitcoin Core's libsecp256k1), pinned.
- **Optional esplora fast path** — off by default, behind an explicit privacy warning in Settings.

## Layout

Architecture invariant: **all logic lives in the SPM package, where it is tested; the app target is a thin shell.** No wallet, protocol, or crypto logic may move into `BTCSwiftApp` — if the UI needs something, expose it from a library.

- `Sources/BitcoinCore` — crypto, keys (BIP39/32/86), Taproot (BIP341), descriptors (BIP380/387/389/390), MuSig2 (BIP327), silent payments (BIP352)
- `Sources/BitcoinP2P` — wire protocol, peers, header chain, BIP157 filter sync, tx broadcast
- `Sources/BlockchainBackend` — opt-in esplora client (never contacted unless enabled)
- `Sources/WalletCore` — wallet/vault actors, sighash + signing, PSBTv2, coin selection, fee policy, import bundles
- `Sources/BTCSwiftApp` — the iOS app (SwiftUI, iOS 17+)
- `docs/` — [design papers](docs/README.md) (phone, read, write, vaults, import) + webpage
- `Scripts/` — icon generation, App Store Connect API tooling, TestFlight pipeline

## Build & test

```sh
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 203 tests, official BIP vectors
/opt/homebrew/bin/xcodegen && open BTCSwiftApp.xcodeproj              # iOS app
```

Default network for development is signet. Point the app at your own
filter-serving node (Settings → Manual peers); the node needs
`blockfilterindex=1` and `peerblockfilters=1`.
