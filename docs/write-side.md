# The Write Side: How a Phone Pays Without Asking Anyone

*Design paper for Winnow. Companion to [the read side](read-side.md) — that paper ends when the UTXOs are local. This one starts there. Framing: [a phone wallet](mobile.md).*

---

## 1. The problem

Once compact filters have answered "what's mine?", spending is four mechanical steps:

1. **Choose coins and a feerate** so the transaction clears dust rules and will relay.
2. **Build** an unsigned transaction whose change is not a fingerprint.
3. **Sign** without leaving the seed in memory or in a file.
4. **Get it out** — and know that it got out — without an API key and without calling the spend "received" at 0-conf.

On a server-backed wallet these collapse to `POST /tx`. On a phone that refuses that server, each step has to be possible with only: the local UTXO set, a handful of outbound peers, and the keychain. This paper is those four steps, as implemented.

---

## 2. One spend shape

Everyday spends are BIP86 P2TR key-path. The signed witness is one 64-byte Schnorr signature (`SIGHASH_DEFAULT`); fee math uses 66 witness bytes per input (compact-size count + length + 64). Script-path and MuSig2 shapes belong to [vaults](vaults.md) and plug into the same builder via `witnessBytesPerInput`.

The phone *receives* only P2TR. It *pays* any standard address (bech32 / bech32m, base58 P2PKH / P2SH) and BIP352 silent-payment codes. Destination diversity is a payment-layer concern; the wallet's own outputs stay one type so coin selection, change, and watch-list code have a single script shape.

Transactions are version 2, empty `scriptSig`s, and sequence `0xFFFFFFFD` (locktime-disabled, BIP125 opt-in RBF). A pending send with change can be fee-bumped in the transaction history; signaling replacement from the first broadcast avoids a policy surprise when it is needed.

---

## 3. Coin selection and change

Largest-first, with Bitcoin Core's dust rule (`policy.cpp` `GetDustThreshold`). At the default dust relay feerate (3000 sat/kvB) a 43-byte P2TR output is dust below **330 sats**. The often-quoted 294 sats is the P2WPKH threshold; using it here would produce outputs some peers will not relay.

The loop accumulates the largest UTXOs until the selection covers the payment plus the fee of the transaction *as currently shaped* (each added input grows vsize, so the fee target moves). A change output is created when the remainder clears the change script's dust threshold; otherwise the remainder is folded into the fee. Feerates outside `(0, 10_000]` sat/vB are rejected (Core's `maxTxFee` ceiling is 0.10 BTC/kvB). Payment outputs that are themselves dust are rejected before a transaction is built — a sub-dust payment would strand the inputs in a tx no peer will take.

Change, when any, goes to the next unused internal address (`tr(…/<0;1>/*)`, choice 1). Its position among the outputs is chosen uniformly at random so change is not "always last" — a well-known chain-analysis fingerprint. After a successful broadcast the spent UTXOs leave the local set immediately and the change UTXO enters it at height 0, so a second send cannot double-spend the unconfirmed inputs. Height 0 is pending, never "confirmed."

**Commit-after-broadcast.** `Wallet.buildSend` produces a signed transaction without mutating wallet state. `commit` runs only after the bytes have been handed to the broadcaster. Committing first and then failing to leave the device would strand inputs in a locally-spent, on-chain-unspent limbo that forward-only scanning cannot repair.

---

## 4. Fees without a mempool

A filter-only client does not see the fee market. Feerates of stranger transactions require their input amounts, which means recursively fetching parents — the bandwidth blowup the read side refused. So this product does not estimate from gossip.

Resolution, strongest first (`FeePolicy`):

1. **User override** (sat/vB), when the send form set one.
2. **Median of this wallet's own recently confirmed spends.** Those feerates are exact: the wallet knows every input amount because it selected them.
3. **Static presets** — low 2, medium 5, high 12 sat/vB. Deliberately above typical minima. A mempool-blind wallet must overpay rather than stall.

The result is clamped from below by the strictest BIP133 `feefilter` among connected peers (the minimum that will relay at all). If every remaining peer's floor later rises above a pending transaction's feerate, the broadcaster emits `feeFloorExceeded` once; the caller decides whether to bump. There is no live histogram and no "arrives in 10 minutes" claim.

This is cruder than any mempool-aware estimator. It is also the only estimator that does not reintroduce a server or a persistent relay subscription. Owned, and said in the send UI as a rate, not as a promise.

### 4.1 Replacing a stuck send

Winnow persists the exact inputs and raw transaction for each locally-created pending send. A replacement spends those same inputs, preserves every recipient output and its ordering, and pays the increase by shrinking the existing change output. If the remainder falls below the change script's dust threshold, change is removed and the whole remainder becomes fee. A changeless transaction cannot be bumped without adding an input, so the same-input flow refuses it rather than altering a recipient amount.

The builder enforces both fee dimensions of BIP125 policy: the replacement's absolute fee and feerate are strictly higher, and the increase pays the default incremental relay fee for the replacement's own virtual size. It uses the same PSBTv2 key-path signer as the original send. Building is mutation-free; the app broadcasts the replacement, commits the wallet-state swap, then cancels relay of the original. If the wallet commit fails, the replacement broadcaster entry is cancelled and the original keeps relaying.

History retains the old txid as **replaced** and adds the new pending entry. If the original wins the confirmation race before the replacement propagates, scanning discards the replacement descendant and its locally-counted change before applying the confirmed original. Conversely, if broadcasting succeeds but the replacement's state commit fails, its exact input set still identifies it as the winner when scanned and removes the original pending change. Neither race can double-count balance.

---

## 5. Signing

The everyday path is PSBTv2 even for single-sig (BIP370/371): creator attaches witness UTXOs and Taproot key-origin metadata, the signer writes `PSBT_IN_TAP_KEY_SIG`, the finalizer extracts a raw transaction. One pipeline with [vaults](vaults.md), instead of a private "just sign it" shortcut that would drift.

Secrets:

- The seed is a BIP39 mnemonic (12 words, 16 bytes of entropy) or a master xprv, stored by `KeychainStore` under the wallet id (master fingerprint, 8 hex chars).
- Accessibility is `WhenUnlockedThisDeviceOnly`; `kSecAttrSynchronizable` is false. The JSON wallet file on disk holds the descriptor, UTXOs, and history — public material.
- `Wallet.tweakedPrivateKey` loads the secret, derives `m/86'/coin'/account'/chain/index`, applies the BIP86 tweak (no merkle root), signs, and drops the key. The actor never holds the seed in `WalletState`.

All secret-key operations go through libsecp256k1 (P256K). The sighash is BIP341 `SIGHASH_DEFAULT` — also the BIP352-safe choice for taproot inputs, which matters in §6. Auxiliary nonce randomness is 32 fresh bytes per signature.

A server that lied about a UTXO *amount* on the (opt-in) esplora path produces an invalid signature, not a theft: the sighash commits to input amounts. A server that hid a payment can only hide it; it cannot spend it. The default path never asks a server.

---

## 6. Silent payments, send-side only

BIP352 `sp1…` / `tsp1…` codes are first-class destinations. The P2TR output script is not known until the input set is fixed — the shared secret is `input_hash · a · B_scan` over the selected inputs' tweaked keys — so coin selection runs against a same-size P2TR *placeholder*, then `SilentPaymentSending.outputScripts` replaces the placeholders at signing time.

Receiving silent payments is out of scope. A receiver must tweak-check every output in every block, which is a different read-side (and a different battery budget) than matching a small watch list against BIP158 filters. The product does not pretend a send-only implementation is "silent payments support." Send is done and vector-tested; receive is a deliberate absence, recorded in [the read side](read-side.md) §3.

Inputs to a silent-payment send are this wallet's own P2TR key-path spends, which is exactly the BIP352 wallet case (the sender controls every eligible input key; shared-control inputs are excluded from derivation).

---

## 7. Getting it out

`TxBroadcaster` is P2P relay, not an API client:

- Announce `inv(MSG_WITNESS_TX)` to the connected pool (default 3 peers).
- Answer `getdata` with the raw transaction.
- Per-peer state: `announced → requested → served`, plus `failed` on timeout/disconnect and `deprioritized` if a peer never answers `maxAnnouncementsPerPeer` invs (then skipped for that tx).
- Re-announce on exponential backoff (60s base, cap 1h) until `FilterSync` reports the tx in a matched block, or the caller cancels (e.g. a replacement).
- Pending txs persist as JSON (raw tx, feerate, next attempt) so a killed app resumes relay.

While the Send screen is open, a [bounded mempool window](read-side.md#28-bounded-mempool-windows) watches for peers echoing our txid back. An echo is evidence the network has the bytes; it is not confirmation. The UI says "broadcast" / "relayed" / "seen in a block", never "sent" at 0-conf.

The opt-in esplora path may POST the same raw transaction as a second route. That POST links the txid to the phone's IP at that server — one of the things the Settings warning names.

---

## 8. What still leaks

Filters protect the *read*. The write is a public announcement.

- The peers you `inv` see your IP and your transaction. They learn the inputs you spend and the outputs you create. Change randomization and Taproot-only outputs shrink fingerprints; they do not hide the spend from the relay peer.
- A network observer between you and those peers sees the same.
- RBF signaling and a recognizable vsize (one 64-byte witness per input) are visible on the wire. That is the cost of a simple spend shape.

There is no Dandelion, no Tor requirement, no equal-output coinjoin. A user who needs those wants a different product (or a vault plus a coordinator they bring themselves). This paper will not claim broadcast privacy the implementation does not provide.

---

## 9. Use cases

| # | Use case | Mechanism |
|---|----------|-----------|
| 1 | Pay a bech32m / bech32 / base58 address | Decode → select → build (random change slot) → PSBT sign → broadcast |
| 2 | Pay a silent-payment code | Same, with output scripts derived after selection |
| 3 | Pick a fee | Override / observed median / preset, clamped by `feefilter` |
| 4 | "Is it out?" | Peer `getdata` + txid echo while Send is open |
| 5 | "Is it done?" | Filter match on a confirmed block; height 0 change flips to that height |
| 6 | App killed mid-relay | Persisted pending set resumes backoff |
| 7 | Peers will not take this feerate | `feeFloorExceeded`; user may bump (RBF already signaled) |
| 8 | Vault spend | Same builder and broadcaster; signing is the [vault](vaults.md) ceremony |

---

## 10. Conclusion

The write side of a phone wallet is not a REST client. It is coin selection that knows P2TR dust, a feerate that admits it is blind, a signing path that holds the seed for one call, and a relay state machine that survives the app being killed. Confirmation still comes from [the read side](read-side.md). Nothing in this paper asks a server, unless the user turned one on and was told what that means.

**v1 is therefore: largest-first P2TR selection + `FeePolicy` + PSBTv2 key-path signing via libsecp256k1 + `TxBroadcaster` over the same peer pool that serves filters.**
