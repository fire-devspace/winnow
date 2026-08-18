---
title: "Public Signet Story Evidence"
description: "Sanitized public evidence for Winnow's reproducible café-to-vault story."
url: "https://winnowwallet.com/evidence"
---

# Public signet story evidence

This is the public, secret-free summary of Winnow's reproducible whole-app run
`whole-app-2026-08-17-r2`, scenario `whole-app-public-signet-v4`.

The run used public signet only. It required no local Bitcoin Core process, RPC
credential, or owner-machine service. Signet coins have no monetary value.

Sofía Cruz, Lina Vega, Elena Rivera, Leo Santos, Marina Ortiz, Mateo Rivera,
Brisa Café, Harbor Exchange, and Ceiba Trust are fictional.

## Environment

| Item | Recorded value |
|---|---|
| Git commit at run start | `33815245f1e9113b7e5368b34dd1cd036170e724` with working-tree changes |
| Scenario | `whole-app-public-signet-v4` |
| Swift | Apple Swift 6.3.3 |
| Xcode | Xcode 26.6, build 17F113 |
| Simulator | iPhone 17 Pro Max, iOS 26.4 runtime |
| Network | Public signet |

## Checkpoint results

| Checkpoint | Result | Evidence summary |
|---|---|---|
| Preflight and public peers | **Passed** | Built and installed without a local Bitcoin node. |
| Sofía opens Brisa Café's wallet | **Passed** | Creation, interrupted-backup resume, completed backup, ready state, and empty balance recorded without inspecting recovery words. |
| First customer payment | **Passed** | Confirmed balance, one UTXO, and history discovered through P2P compact-filter synchronization. |
| Supplier payment and fee replacement | **Passed** | Original plus two replacements observed; final replacement confirmed. |
| Silent Payments | **Deferred / incomplete** | A transaction was observed, but receive, detection, export/import, and spend did not complete. It is not counted as passed. |
| Rivera 2-of-3 cold reserve | **Passed** | Funding, Elena + Leo ordinary spend, and Leo + Marina recovery spend confirmed. |
| Rivera 2-of-2 MuSig2 reserve | **Passed** | Nonce and signing rounds completed; key-path spend confirmed with one 64-byte witness item and no revealed script. |
| Replacement phone | **Passed** | Balance, one UTXO, five history entries, replacement links, scan height, and peers matched the source. |
| Trust and privacy tour | **Passed** | Public peers, manual-peer controls, explorer warning/cancellation, experimental Silent Payment warning, and paper access captured. |
| Publication | **Awaiting human media review** | Automated text redaction passed; screenshots and video frames still require human inspection before publication. |

## Confirmed public transactions

| Event | Transaction | Confirmed block |
|---|---|---:|
| Customer funding | [`44890b72d9910a4ad9390a1f1e1ade446bde809ceb1736128274199e48e935c0`](https://explorer.bc-2.jp/tx/44890b72d9910a4ad9390a1f1e1ade446bde809ceb1736128274199e48e935c0) | 318128 |
| Final supplier RBF replacement | [`543a9cf35d1db26dc8b656d78a3b6c5fe88d23b4a4710883f521f6800814ff65`](https://explorer.bc-2.jp/tx/543a9cf35d1db26dc8b656d78a3b6c5fe88d23b4a4710883f521f6800814ff65) | 318146 |
| Cold-reserve funding | [`0e860e416d346caca681f2a1b6016f9976787c363b2a4e1178bf2c07d0ebe791`](https://explorer.bc-2.jp/tx/0e860e416d346caca681f2a1b6016f9976787c363b2a4e1178bf2c07d0ebe791) | 318176 |
| Elena + Leo ordinary path | [`46081b3dfb1f841bf5642737082cb88e376cc6f967fba2109ce55991aa0e698a`](https://explorer.bc-2.jp/tx/46081b3dfb1f841bf5642737082cb88e376cc6f967fba2109ce55991aa0e698a) | 318180 |
| Joint-reserve funding | [`995bedd34e108a9d640ebb0c005cb1519e156059086c7349918a4e1198b4761c`](https://explorer.bc-2.jp/tx/995bedd34e108a9d640ebb0c005cb1519e156059086c7349918a4e1198b4761c) | 318180 |
| Leo + Marina recovery path | [`7df05a8190ccfd3ae7f39e48118616cbe210561c74d41d7f23328e86e6028cbb`](https://explorer.bc-2.jp/tx/7df05a8190ccfd3ae7f39e48118616cbe210561c74d41d7f23328e86e6028cbb) | 318181 |
| Elena + Mateo MuSig2 spend | [`1b1261381ae44e1d3a0d99bfbc2bb9d428223a45f2a26642b0fcf7a17c51dc03`](https://explorer.bc-2.jp/tx/1b1261381ae44e1d3a0d99bfbc2bb9d428223a45f2a26642b0fcf7a17c51dc03) | 318182 |

The original and intermediate supplier transactions were observed by the run
but intentionally replaced. They are retained in wallet history as replacement
links rather than listed as confirmed spends.

## What this evidence does not claim

- It does not establish mainnet release readiness.
- It does not prove Silent Payment receiving works end to end.
- It does not claim a compact-filter phone is a full validating node.
- It does not publish recovery phrases, private keys, secret nonces, wallet
  entropy, unredacted exports, or unreviewed media.
- It does not present Harbor Exchange or Ceiba Trust as real services.

Read the [canonical design paper](paper.html) for the architecture and threat
model, or [return to Sofía's story](index.html#story).
