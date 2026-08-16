# Import: The Bundle Is the History

*Design paper for Winnow. The no-back-scan rule is stated in [the read side](read-side.md) §2.7.5 and [the phone paper](mobile.md) §4.1. This is the format, the verification algorithm, and what a lying bundle can still do.*

---

## 1. The problem

A private light client that starts at the tip is cheap. A private light client that starts in 2018 is not: years of compact filters are multiple gigabytes (approx.), and the phone would have to download them to learn a balance it *already knew* in the previous wallet.

So this product does not back-scan. A new wallet is created here and scans forward. An existing wallet may be imported **only with its history included**. The previous software already did the scanning; it must give this phone the answers, plus a height those answers claim to be current as of. This phone then *checks* those answers against the chain, forward from that height, and continues.

The bundle is not a convenience file. **The bundle is the history.** Without it there is no import.

---

## 2. Format (version 1)

JSON, one object:

```json
{
  "version": 1,
  "network": "signet",
  "descriptor": "tr([fp/86'/1'/0']tpub…/<0;1>/*)#checksum",
  "mnemonic": "word …",
  "lastKnownHeight": 150000,
  "utxos": [
    {
      "txid": "<display hex>",
      "vout": 0,
      "amount": 50000,
      "scriptPubKey": "5120…",
      "chain": 0,
      "index": 3,
      "height": 149000
    }
  ],
  "transactions": [
    {
      "txid": "<display hex>",
      "height": 149000,
      "received": 50000,
      "spent": 0,
      "fee": 250
    }
  ]
}
```

Rules the importer enforces before any network call:

- `version` must be `1`. Unknown versions fail closed.
- `network` is `signet` or `mainnet` (the two networks the app opens).
- At least one of `descriptor` or `mnemonic` is present.
- If both are present they must *agree*: the BIP86 descriptor derived from the mnemonic equals the bundle descriptor, or import throws `descriptorMismatch`.
- Mnemonic-only: the app derives the canonical `tr([fp/86'/coin'/0']xpub/<0;1>/*)` and stores the mnemonic in the keychain (spendable).
- Descriptor-only: watch-only. The descriptor must be that same single-sig shape. Signing is impossible until a secret is supplied by some later path (there is none in v1 — watch-only stays watch-only).
- Every claimed UTXO's `scriptPubKey` must be exactly what the descriptor derives at `(chain, index)`. A bundle cannot attach an arbitrary output to this wallet by lying about coordinates.
- `txid` values are display (big-endian) hex on the wire and in the file; internally they are reversed to Bitcoin's byte order, same as the rest of the stack.
- `chain` is `0` receive / `1` change (BIP44 external/internal, matching the multipath descriptor).
- Scanning resumes at `lastKnownHeight + 1`. `creationHeight` of the new wallet state *is* `lastKnownHeight`.
- `fee` on a history entry is optional. The writer includes it only when every input of that transaction was ours (the only case a filter client can compute the fee exactly). Older v1 files omit the key; readers treat absence as unknown. This is display state — omitting it does not create or destroy money. The on-device `observedFeeRates` samples FeePolicy uses are **not** in the bundle; a restored wallet falls back to the static presets until it observes new sends.

The format is versioned so a future `proof` field (Utreexo, [read-side](read-side.md) §5.3) can be added without breaking v1 readers.

Vaults are not in this bundle. A vault is a separate descriptor the user adds in-app; its history follows the same forward-only rule ([vaults](vaults.md) §5).

---

## 3. Verification

`Wallet.importing` seeds state *exactly as the bundle claims*. That is intentional: the phone must be able to watch the claimed scripts in order to check them. `Wallet.verifyImport` then runs `FilterSync` from `lastKnownHeight + 1` and builds an `ImportReport`:

| Field | Meaning |
|-------|---------|
| `scannedFromHeight` / `scannedToHeight` | The forward window actually scanned. |
| `confirmedUTXOs` | Claimed by the bundle and still unspent after the scan. |
| `spentSinceBundle` | Claimed UTXOs the scan saw spent. Stale or wrong bundle. |
| `discoveredUTXOs` | Found by the scan, absent from the bundle (payments after export). Informational. |

`matchesBundle` is `spentSinceBundle.isEmpty`. A stale export (you spent after you wrote the file) is a report the user can see, not a silent rewrite. Discovered UTXOs are applied — the point of the forward scan is to catch up — but a claimed-and-spent coin is never left in the spendable set as if the bundle were current.

The report core (`ImportReport.make`) is a pure function of the bundle plus the `MatchEffect`s of the scanned blocks, so it is unit-tested without a network. The e2e suite drives the real app through an import and captures the report screen (`14-import-report.png`); latest run spent 15.82s in verify (signet, 2026-08-15, `screenshots/timings.json`).

Cost is proportional to how stale the bundle is, not to how old the wallet is. A bundle exported at the tip is a JSON parse and a zero-length scan.

---

## 4. What a lying bundle can and cannot do

The bundle is trusted as a *starting claim*, then checked against filters. That is a weaker assumption than "the file is true," and a stronger one than "the file is untrusted input from the internet."

A malicious bundle **cannot**:

- Make this wallet spendable for an output it does not derive. ScriptPubKey / `(chain, index)` disagreement fails import.
- Change the descriptor behind a mnemonic. Mismatch fails import.
- Invent a spendable coin that never existed *and have it survive verify*. A claimed outpoint that is not in the chain will not be confirmed by a filter match; a claimed outpoint that was spent will land in `spentSinceBundle`.
- Put the seed in iCloud. The mnemonic, if present, goes to `KeychainStore` with the same this-device-only policy as a freshly created wallet.

A malicious bundle **can**:

- Omit a UTXO you actually own. Verify will not invent it unless a forward-scan block happens to pay you again (or still contains it — it won't, it's old). **Omission of old coins is the residual lie**, and it is the same lie as any incomplete export. The mitigation is: export from software you trust, inspect the report, do not import a bundle a stranger handed you as a way to "recover" funds.
- Omit history entries. The history list is for display; the spendable set is the UTXOs. Missing history does not create money.
- Point `lastKnownHeight` too high, so the forward scan skips the window in which a claimed coin was spent. Then `spentSinceBundle` stays empty and a spent coin looks live until some later spend attempt fails, or a later rescan from a lower height. **A too-high height is the dangerous lie.** The importer does not currently prove the height against a checkpoint the previous wallet signed. Mitigation: treat a bundle from an unknown height as suspect; prefer exports that name a height you can see on a header explorer you already use; the report shows the window that was actually scanned.
- Point `lastKnownHeight` too low. That only makes the forward scan longer. Harmless except for bandwidth.

This is the import analogue of [read-side](read-side.md) §2.7.1 (filters can lie by omission). Here the *file* can lie by omission or by a too-high height. The chain check catches spends inside the scanned window. It does not reconstruct a past the bundle refused to include.

---

## 5. Export (the writer)

Winnow produces the same v1 JSON it consumes. Settings → **Export wallet bundle** writes descriptor + known UTXOs + history (including `fee` when known) + `lastKnownHeight` = the live FilterSync frontier (`nextScanHeight − 1`). The app persists that frontier back into `WalletState` after each sync pass — `apply(match:)` alone does not move it — so an export after ordinary app use resumes where the phone actually stopped, not at the creation/import height. The mnemonic is **excluded by default**; including it is a hot backup and takes an explicit toggle plus a confirm. The on-screen preview redacts the mnemonic line; the shared file is the real JSON. The share-sheet file is a unique, backup-excluded temp that is deleted when the sheet closes, the seed toggle flips, or the write fails. A missing keystore entry or an xprv-only wallet throws `mnemonicUnavailable` rather than a raw keystore error.

A Winnow-native wallet that is never exported cannot be recovered here from the 12 words alone — that is the no-back-scan rule, not a missing feature of import. Export is the other half.

Pending (height 0) change outputs stay in the UTXO set: they are live spendable state.

---

## 6. What this is not

- **Not a BIP39-only import.** A 12-word phrase without history would force a back-scan. The onboarding UI does not offer "type your words and we'll find your coins."
- **Not an xpub watcher that asks an indexer.** Descriptor-only import is watch-only and still uses filters, from the bundle height forward. The opt-in esplora path does not get to skip the bundle.
- **Not SLIP-39 / Passport / SeedQR / output descriptors of every flavor.** v1 is the everyday BIP86 wallet this app itself creates. That is the export we can specify and the import we can verify. Broader descriptor import is a format-version bump, not a silent widening of `tr(KEY)`.

---

## 7. Conclusion

Moving a wallet onto this phone is a data-portability problem, not a scanning problem. The previous wallet ships its answers; this wallet checks the answers it can check (spends after `lastKnownHeight`, script/descriptor agreement) and refuses to pretend the rest of history can be privately reconstructed on a radio.

**v1 is therefore: a versioned JSON bundle (descriptor and/or mnemonic + UTXOs + history + height), seeded as claimed, verified by forward filter-scan, with omissions and too-high heights documented as residual risk rather than solved.**
