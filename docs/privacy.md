# Winnow Privacy Policy

**Winnow collects nothing.** No accounts, no analytics, no crash-reporting beacons, no advertising SDKs, no server of ours exists to collect anything with.

## What the app does with your data

- **Keys never leave your device.** Seed material is generated on-device and stored in the iOS Keychain (this-device-only, never synced).
- **No address leakage by default.** The wallet learns its own transaction history by downloading compact block filters (BIP157/158) from random Bitcoin full-node peers and matching them *on your device*. Your addresses are never transmitted. As with any direct network connection, peers see your IP address; the app deliberately rotates and holds no fixed relationship with any peer.
- **Mempool windows.** While the Receive screen is open, the app subscribes to ordinary transaction-relay traffic and matches it locally — the same data every full node sees. Nothing about you is queried or revealed.
- **Broadcasting.** Signed transactions are relayed directly to P2P peers.
- **External explorer links.** Settings lets you choose mempool.space or a custom Esplora-compatible website. Winnow never queries it automatically. If you tap an address or transaction link, a warning identifies that the selected service will learn your IP and the exact item before iOS opens it.
- **Experimental silent-payment receiving.** If explicitly enabled, Winnow requests block-wide tweak data from the service you choose. The service sees your IP following silent-payment blocks but is not given your address or balance. Matching stays on-device; an incomplete service can cause a missed payment.
- **Third-party code.** One dependency: libsecp256k1 (via the P256K Swift package). It makes no network calls.

## Contact

a@wuli.nu · Source code: https://github.com/posix4e/winnow
