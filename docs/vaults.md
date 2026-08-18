# Vaults: Shared Custody That Still Fits on a Phone

> **Archived technical note.** Winnow's current architecture, evidence, and
> limitations now live in the [canonical design paper](paper.md).

*Design paper for Winnow. A vault is another descriptor on the same [read](read-side.md) / [write](write-side.md) path — not a second wallet architecture. Framing: [a phone wallet](mobile.md).*

---

## 1. The problem

Shared custody on a phone usually means one of three things, all bad for this product:

- A **vendor coordinator** that sees every proposal, every cosigner, and when you spend.
- A **legacy multisig** script (`OP_CHECKMULTISIG`) with ECDSA, redeem-script fingerprints, and a larger on-chain footprint than the everyday Taproot wallet.
- A **QR-code theatre** that hides an underspecified PSBT behind "scan this" and hopes the review screen shows the right destination.

The constraint is the same as the rest of the app: no server by default, Taproot only, logic in the library, the phone is a signer you can hold. So a vault here is a descriptor plus a PSBTv2 file you can AirDrop. The phone never runs a coordinator. The PSBT *is* the coordinator.

Two policies are supported — and only these two. Both are Taproot. Both reuse `FilterSync`, `CoinSelection`, `FeePolicy`, and `TxBroadcaster`.

---

## 2. The two policies

### 2.1 Script-path k-of-n — `tr(NUMS, sortedmulti_a(k, …))`

BIP387 `multi_a` / `sortedmulti_a` in a single tapscript leaf. The internal key is the BIP341 NUMS (nothing-up-my-sleeve) point (`Taproot.unspendableInternalKey`). No party has the corresponding secret, so **there is no key-path spend**. The only way out is the leaf.

`sortedmulti_a` is the constructor the app emits (`Vault.multiADescriptor`): keys are sorted, so independently constructed descriptors agree. `multi_a` (unsorted) is accepted on import so a descriptor built elsewhere still opens.

On-chain this is visibly a script-path spend: control block + leaf script + k signatures. That is a privacy cost relative to everyday key-path spends, paid for an honest k-of-n (a 2-of-3 inheritance vault, a 2-of-2 with a recovery key, and so on). The witness is larger; coin selection is told the exact `witnessBytesPerInput` for that leaf so the fee is not a guess.

### 2.2 Key-path n-of-n — `tr(musig(k1, k2, …)/…)`

BIP390 `musig()` aggregated with BIP327 MuSig2, typically with a BIP328 derivation suffix. The on-chain output is an ordinary P2TR key-path spend: one 64-byte signature. Watchers cannot tell a MuSig2 vault from the everyday single-sig wallet.

The cost is interactive signing (nonces, then partials) and the n-of-n shape — there is no k < n. A party who loses a key cannot fall back to a leaf; if you need that, use §2.1.

The app does not mix the two in one descriptor (no `tr(musig(…), multi_a(…))` first cut). One policy per vault keeps the review screen and the PSBT fields honest.

---

## 3. Why these two, and not the rest

- **No `OP_CHECKMULTISIG` / P2WSH / P2SH.** They reintroduce ECDSA, a second address type, and a watch-list the compact-filter path would have to treat as special. The product is Taproot-only ([mobile](mobile.md) §4.2).
- **No unspendable-internal-key *and* a MuSig2 key-path in one output.** That construction exists in the BIP zoo; it is a third review surface and a third witness-size path. Two policies cover the two stories users actually have: "k of us must agree, and nobody has an escape hatch" versus "all of us must agree, and the chain sees a single signature."
- **No coordinator protocol.** Frost, MuSig2 with a signing server, or a proprietary "vault API" would put a third party on the write path. Cosigners exchange PSBTs. How they exchange them is their problem — the library does not open a socket for it.

---

## 4. The ceremony is PSBTv2

Roles (BIP370/371/373), as the library actually implements them:

1. **Creator** (`Vault.createSpend`). Same coin selection and unsigned tx as `Wallet.buildSend`, then vault fields:
   - *multi_a:* BIP371 leaf script, control block, per-key origins (fingerprint + full path at `(choice, index)`).
   - *MuSig2:* BIP373 participant pubkeys and the BIP328-derived internal key.
   - Change, if any, goes to choice 1 at `changeIndex` and carries `PSBT_OUT_TAP_TREE` / internal key / derivations so a cosigner can see it is *this vault's* change, not an unknown output.
2. **Signer** (per cosigner, on their own phone). For multi_a: a BIP342 script-path signature with the plain x-only key (no taproot tweak — the sighash commits to the leaf). For MuSig2: nonce generation, then a partial signature, in the BIP373 fields. Secrets load from that device's keychain for the call, same as the everyday wallet.
3. **Combiner.** Union-merge of partial PSBTs. Order-independent; a 2-of-3 can combine in any sequence.
4. **Finalizer / extractor.** Witnesses assembled, raw transaction out, then [the write side](write-side.md) §7 broadcasts it.

The review screen (`VaultSignView`) runs *before* the key is used. It lists every destination, flags vault change via the output derivation fields, and shows the fee and sighash. A cosigner who cannot explain an output does not sign. That is the whole anti-"QR theatre" mechanism: the PSBT carries enough metadata to review, and the UI refuses to skip it.

---

## 5. The read side does not care

A vault is a `tr(…)` descriptor. `watchScripts(upTo:)` derives both multipath choices for a gap of indices and drops them into the same filter stream as the everyday wallet. There is no per-vault server, no "subscribe this multisig," no extra bandwidth for a 2-of-3 versus a 1-of-1.

Creation height still matters. A vault whose first output is older than the phone's scan start will not be discovered by filters — same fresh-wallet / forward-only rule as everything else. Import the history, or create the vault in this app and use it from now on. [Import](import.md).

---

## 6. What a vault is not

- **Not a recovery mnemonic for the everyday wallet.** Losing the phone still loses the everyday seed unless the user wrote it down. A 2-of-3 vault is how you *plan* for lost devices; it is not automatic.
- **Not threshold MuSig.** k-of-n with a single-signature on-chain footprint is a different scheme (FROST, etc.) and a different paper. Here, k-of-n is the leaf, n-of-n is MuSig2.
- **Not private against your cosigners.** They see the spend. They should: they are signing it.
- **Not private against chain watchers in the multi_a case.** Script-path is visible. MuSig2 is not.

---

## 7. Conclusion

Shared custody on this phone is two Taproot descriptors and a file format. The NUMS internal key makes k-of-n honest (no hidden key-path). MuSig2 makes n-of-n quiet (one signature). PSBTv2 is the only coordinator. The read path does not change.

**v1 is therefore: `tr(NUMS, sortedmulti_a(k, …))` and `tr(musig(…)/…)`, created and cosigned on-device, broadcast on the same P2P path as a single-sig spend.**
