# Winnow Privacy Policy

**Winnow collects nothing.** No accounts, no analytics, no crash-reporting beacons, no advertising SDKs, no server of ours exists to collect anything with.

## What the app does with your data

- **Keys never leave your device.** Seed material is generated on-device and stored in the iOS Keychain (this-device-only, never synced).
- **No address leakage by default.** The wallet learns its own transaction history by downloading compact block filters (BIP157/158) from random Bitcoin full-node peers and matching them *on your device*. Your addresses are never transmitted. As with any direct network connection, peers see your IP address; the app deliberately rotates and holds no fixed relationship with any peer.
- **Mempool windows.** While the Receive screen is open, the app subscribes to ordinary transaction-relay traffic and matches it locally — the same data every full node sees. Nothing about you is queried or revealed.
- **Broadcasting.** Signed transactions are relayed directly to P2P peers.
- **Optional esplora mode.** If you explicitly enable an esplora backend in Settings (off by default, behind a warning), that server operator can link the addresses you query to your IP. The app tells you this before you turn it on.
- **Third-party code.** One dependency: libsecp256k1 (via the P256K Swift package). It makes no network calls.

## Contact

a@wuli.nu · Source code: https://github.com/posix4e/winnow
