# A Private Bitcoin Wallet on a Phone

*Framing paper for btc-swift. The other papers — [read](read-side.md), [write](write-side.md), [vaults](vaults.md), [import](import.md) — each own one job. This one owns the device.*

---

## 1. The constraint

A Bitcoin wallet is keys plus four questions about the chain (what's mine, where's the tip, what fee, did my transaction get out). On a desktop, any of the usual answers work. On a phone, most of them don't.

A phone is not a full node: it will not download, store, or validate the chain. A phone is also a poor thin client of someone else's node: it has a stable identity (an IP, an Apple ID, a push token), it is almost always on a network that can be logged, and the user will not read a privacy policy before tapping Receive.

The product lives in the space between those two refusals. **The phone does the matching. Nobody is asked which addresses are yours. The chain is not stored. Work happens while the app is open.** Everything else — Taproot-only, fresh wallets, import-with-history, bounded mempool windows, an esplora toggle behind a warning — is a consequence of that sentence, not a feature list.

This paper states the device constraints, the architecture they force, and which paper answers which question. It does not re-argue compact filters; that is [the read side](read-side.md).

---

## 2. What a phone actually is

Constraints that are load-bearing, not stylistic:

- **Outbound TCP only.** The app talks to full-node peers over `Network.framework`. No inbound ports, no hidden services, no background socket the OS will kill. Peers are a small outbound pool (default 3): manual endpoints first, then a persisted good-peers list, then a few hardcoded fallback peers (IP literals verified filter-serving; see `NetworkParams`) racing the DNS-seed results — dialed a batch at a time with a short per-attempt timeout, so a fresh launch fills the pool in seconds and reports exhaustion instead of spinning forever. No addr gossip, no scoring buckets — a misbehaving peer is dropped and replaced.
- **Foreground only.** There is no `UIBackgroundModes` entry. Sync-while-active is the design, not a v1 omission. A payment you are not looking at waits for the next open, or for a confirmation the next time filters are scanned. Push notifications would require a server that knows your addresses or your txids.
- **This-device keychain.** Secrets live in the iOS Keychain as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, with iCloud Keychain sync off. They are not in the app's JSON state, not in iCloud backup, not in the mnemonic UI after the first screen. Signing loads the secret for the call and drops it.
- **One runtime dependency.** [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) — Bitcoin Core's libsecp256k1. Swift never does raw curve math on secrets. Everything else (filters, headers, PSBT, descriptors, P2P) is in-tree.
- **App Store reality.** No embedded full node, no always-on VPN, no custom kernel. iOS 17+, iPhone only, portrait. The app target is a thin SwiftUI shell; if the UI needs a capability, a library exposes it. That split is an architecture invariant, not a directory preference: tests run against the SPM package, not against views.

Bandwidth and battery are real but secondary. Steady-state compact filters are a few megabytes a day (approx.; see [read-side](read-side.md) §2.5). The worse mobile cost is *policy*: an always-on mempool subscription, a historical back-scan, or a server that answers `getbalance`. Those are refused even when the radio would allow them.

---

## 3. The four jobs, and two more

| Job | Default on this phone | Paper |
|-----|----------------------|-------|
| What's mine? | BIP157/158 filters, matched on-device, from creation height forward | [read-side](read-side.md) |
| Where's the tip? | 80-byte headers, PoW + chainwork | [read-side](read-side.md) |
| What fee? | User override, else median of *our* confirmed spends, else presets; clamped by BIP133 `feefilter` | [write-side](write-side.md) |
| Did my tx get out? | `inv` → `getdata` → `tx` to the peer pool, rebroadcast until a filter match, echo-watch while Send is open | [write-side](write-side.md) |
| Who holds the keys? | This-device Keychain; Taproot key-path for the everyday wallet | this paper, [write-side](write-side.md) |
| Shared custody? | MuSig2 n-of-n or `multi_a` k-of-n, coordinated by PSBTv2, no server | [vaults](vaults.md) |
| Moving a wallet in? | A history bundle. There is no back-scan. | [import](import.md) |

One opt-in crosses several rows: an esplora backend, off by default, named in Settings with exactly what it learns. It is a user-initiated exception, never the default path.

---

## 4. What the device forces onto the wallet

### 4.1 Fresh, and forward-only

A new wallet is created in the app. It has no history, so scanning starts at the tip (or the height at creation) and runs forward. Recovering an old wallet *privately from the chain* would mean gigabytes of historical filters on a radio the user pays for. The product does not do that. Import requires the previous wallet's answers to come along — descriptor, UTXOs, history, a last-known height — and the phone verifies them by scanning *forward* from that height. The argument and the bundle format are [import](import.md).

This is the constraint that makes the rest cheap. It is not a v1 shortcut.

### 4.2 Taproot only

Receiving is BIP86 P2TR. There is no legacy / nested-segwit / P2WPKH path, and no ECDSA signing path. One output type means one watch-list shape, one sighash, one witness size for fee math (66 bytes for a key-path spend), and no "which address type did this contact use?" branch in the UI.

The phone can *pay* any standard address (bech32/bech32m, base58 P2PKH/P2SH) and can *send to* BIP352 silent-payment codes (`sp1…` / `tsp1…`). It cannot *receive* silent payments — that scan is a different, heavier read-side, and is a deliberate absence ([read-side](read-side.md) §3).

### 4.3 Two modern multisig flavors, same read path

A vault is another descriptor and another watch list. The phone does not run a coordinator, a coinjoin server, or a notification service for cosigners. The PSBT *is* the coordinator; AirDrop, a file, a message are the transport. [Vaults](vaults.md).

### 4.4 Default network is signet

Development and the shipped TestFlight path target signet. Mainnet is in the Settings picker and has its own on-device wallet; it is not the network the e2e suite, the screenshots, or the timings are taken on. The papers describe the protocol as it runs on any network; the numbers in `screenshots/timings.json` are signet.

---

## 5. Trust on a phone

What the user is asked to trust, stated as mechanisms rather than intentions:

- **The keychain and the device.** A stolen backup does not contain the seed. A stolen *phone* that can be unlocked does. This-device-only is not a substitute for a passphrase or a vault; it is the floor.
- **libsecp256k1.** Curve math on secrets is not our Swift. Side-channel claims against the wallet's signing path are claims against that library, or against how we call it (we pass 32-byte auxiliary randomness from `SystemRandomNumberGenerator` per BIP340).
- **The peers you can reach.** Compact filters are not consensus-committed. Multi-peer `cfcheckpt` / `cfheaders` comparison detects disagreement; it cannot prove which peer lied, and a fully eclipsed phone can be shown a consistent lie. Manual peers exist so a user who *has* a node they trust can skip DNS seeds. The residual risk is [read-side](read-side.md) §2.7.1 and §2.9.
- **No one, on the read path, by default.** No server is handed an address, an xpub, or a scripthash. A network observer sees a compact-filter client syncing from a height — the same bytes every such client downloads.

What the user is *not* asked to trust: an indexer operator's retention policy, a push-notification vendor, iCloud Keychain, or the app target. Wallet, protocol, and crypto logic are forbidden from moving into `BTCSwiftApp`.

---

## 6. Deliberate absences

These are product decisions, not missing tickets:

- Always-on mempool / background 0-conf / live fee histograms
- Historical filter back-scan
- Silent-payment receive
- BIP37, Electrum, or any "ask a node about my address"
- An embedded consensus engine or fraud-proof verifier
- A vault coordinator server
- Cloud backup of the seed

Each absence has a paper that says what you get instead. The landing page lists the user-visible costs (slower news, coarser fees, bring your history, sending still shows at the relay peers). This list is the engineering version of the same honesty.

---

## 7. How the implementation is checked

The validation appendix of [the read side](read-side.md) covers the stack. The mobile-specific claim — that the *app* does what the libraries promise — is the signet UI suite: it drives the real binary, mines to it, spends from it, cosigns a vault, verifies an import, and writes the screenshots on this site plus `screenshots/timings.json`. Latest run (iPhone 17 simulator, 2026-08-15): wallet create 1.78s, address shown 2.17s, mined→filter-detected 0.75s, form→broadcast 0.67s.

The suite is ~200 tests plus those UI scenarios, on every push.

---

## 8. Status

Protocol core, both vault schemes, silent-payment send, and the P2P read/write path are complete and vector-tested. The app runs on signet. Mainnet is available and treated as needing more care than a picker flip.

**v1 is therefore: a foreground iOS client, Taproot-only, fresh-wallet, one dependency, talking only to `NODE_COMPACT_FILTERS` peers unless the user opts into a named server — with the four jobs split across the papers that follow.**
