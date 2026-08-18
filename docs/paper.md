---
title: "Winnow: From a Phone Wallet to Family Custody"
description: "A mobile-first Bitcoin wallet architecture for private discovery, direct payment, Taproot shared custody, and portable recovery."
url: "https://winnowwallet.com/paper"
---

# Winnow: From a Phone Wallet to Family Custody

*A canonical design paper for Winnow, August 2026.*

## Abstract

A phone wallet is often a remote control for somebody else's wallet server. It
creates keys locally, then gives an indexer enough information to answer the
questions that make the wallet useful: what has been received, what remains
unspent, what confirmed, and what should be broadcast.

Winnow takes a different position. A phone cannot be a full validating node,
but it can verify Bitcoin's proof-of-work header chain, obtain compact block
filters from ordinary peers, match those filters locally, fetch relevant
blocks, construct and sign transactions, and relay them over the peer-to-peer
network. That read and write path can serve a single-key hot wallet, a Taproot
script-path threshold reserve, and a MuSig2 key-path reserve without adding a
coordinator service.

This paper explains the design through a fictional business. Sofía Cruz uses a
small wallet to run Brisa Café, moves savings into a Rivera family 2-of-3 cold
reserve, and prepares a 2-of-2 MuSig2 reserve for the next generation. The
people and institutions are fictional. The transactions used as evidence were
broadcast and confirmed on public signet, where coins have no monetary value.

The paper uses four status words deliberately:

| Status | Meaning |
|---|---|
| **Implemented** | Present in the current code and covered by deterministic tests. |
| **Verified on signet** | Exercised in the reproducible public-signet story and backed by public transaction evidence. |
| **Experimental** | Available only with an explicit warning and unresolved privacy or reliability constraints. |
| **Planned** | Designed or tracked, but not represented as working product behavior. |

## 1. The custody ladder

The usual wallet comparison asks which application should hold a person's
Bitcoin. Sofía's story starts with a different question: which policy should
protect each kind of money?

### 1.1 Daily money: Sofía alone

Customers pay Brisa Café throughout the day. Sofía must be able to receive and
spend from one phone. The cost of this convenience is clear: the hot-wallet key
is available to that device after authentication.

The wallet is created locally. Its recovery phrase can be copied during
onboarding or later from Settings behind device authentication. Creation and
backup do not wait for the header chain. Synchronization is a background task,
not a prerequisite for generating keys or writing down recovery material.

### 1.2 Business savings: any two of three

At closing time Sofía leaves enough for the next day's expenses and sweeps the
rest into the Rivera cold reserve. It has three named key holders:

- Elena Rivera, the family steward;
- Leo Santos, a custodian at the fictional Harbor Exchange; and
- Marina Ortiz, an officer at the fictional Ceiba Trust.

Any two keys can spend. Elena and Leo form the ordinary operating path. Leo and
Marina form a recovery path if Elena cannot participate. Bitcoin enforces the
threshold; legal and family processes determine when the recovery path should
be used.

### 1.3 Joint family money: both of two

Elena and Mateo Rivera hold the next-generation reserve together. MuSig2
aggregates their keys and signature contributions. Both people must cooperate,
but the final Taproot key-path spend has the same on-chain witness shape as an
ordinary single-key Taproot spend.

These are not three wallet architectures. They are three descriptors using the
same chain, filter, transaction, and storage machinery.

## 2. The phone is the constraint

A phone is intermittent. The application can be suspended, killed between
protocol rounds, moved between networks, or left offline for days. Storage,
bandwidth, and battery matter, but continuity is the sharper constraint.

Winnow therefore adopts the following boundaries:

1. **No local Bitcoin Core requirement.** The application speaks the Bitcoin
   peer protocol; the owner does not operate an RPC service for the phone.
2. **No wallet-server read path by default.** An Esplora endpoint may be chosen
   for human explorer links, but it does not supply balances, histories, fee
   estimates, discovery, or broadcast.
3. **Fresh and forward-oriented.** A newly created wallet scans from its
   creation height. Recovery carries public history rather than silently
   outsourcing a full historical search.
4. **Taproot-first output policy.** The wallet receives to BIP86 Taproot and
   expresses shared custody through Taproot script and key paths. It may pay
   standard legacy destinations when a recipient requires them.
5. **Interruption is normal where replay is safe.** Header sync, filter sync,
   PSBT exchange, broadcast, and public-signet waits are resumable and
   idempotent. A MuSig2 secret-nonce session is the deliberate exception:
   leaving before round 2 abandons it rather than persisting reusable nonce
   material.

The design does not claim a phone is a full node. It verifies header proof of
work and block inclusion for relevant data, but it does not execute every
consensus rule for every block.

## 3. Threat model and trust boundaries

Winnow tries to prevent a wallet service from learning a stable set of wallet
identifiers. It does not promise network anonymity or immunity from a complete
eclipse.

| Component | It may learn | It must not receive by default |
|---|---|---|
| Bitcoin peer | IP connection, timing, public header/filter ranges, requested blocks | addresses, descriptors, scan keys, balance query |
| Selected explorer | IP address and the specific public item the user opens | automatic wallet history or background address queries |
| PSBT cosigner | the transaction proposed for joint authorization | another signer's private key |
| Silent Payment tweak provider, when enabled | IP address, network, fixed public block ranges | scan key, spend key, address, matched output, balance |
| Export recipient | exactly the bundle the user chooses to share | unredacted recovery material in logs or previews |

Multiple peers reduce dependence on a single view. Header synchronization
tries another connected peer when one supplies stale, malformed, invalid, or
nonconnecting headers. Successfully verified headers survive the retry. Local
storage corruption is reported separately and is not treated as a peer fault.

Compact-filter commitments are part of the P2P protocol, not Bitcoin's
consensus commitment. Comparing distinct connected peers detects disagreement,
and a downloaded matching block can be checked against its header. A fully
eclipsed client can still be shown one coordinated view. Manual peer controls
exist for people who want to select a node they trust.

## 4. Learning from Bitcoin

The standard read path is:

```text
Bitcoin peers
    → proof-of-work block headers
    → compact-filter checkpoints and filter headers
    → BIP158 basic filters
    → local script matching
    → matched full block from a peer
    → header, block-hash, and Merkle-root checks
    → wallet and vault state
```

### 4.1 Headers establish the chain

An 80-byte Bitcoin block header commits to the previous block and to the
current block's transaction Merkle root. Winnow validates header linkage,
proof of work, difficulty behavior for the selected network, and accumulated
chainwork. Headers establish where the best known chain is before wallet data
is considered.

This work happens in the background. A person does not need the current tip to
generate a seed, derive a receive address, or complete backup.

### 4.2 Compact filters invert the query

BIP37 Bloom-filter clients sent a personalized filter to a peer. BIP157/158
invert that relationship: a node constructs a deterministic basic filter for
each block and serves the same filter to any client. The client downloads the
public filter and performs its wallet-specific match locally.

Winnow derives candidate scripts for its wallet and vault descriptors, checks
the BIP158 filters on the phone, and fetches a full block only after a match.
Filter hashes link into filter headers. Checkpoints and multiple peers help
identify disagreement. A relevant block is checked against the proof-of-work
header chain before its transactions change wallet state.

### 4.3 The mempool is intentionally bounded

Compact block filters describe confirmed blocks, not the mempool. Normal
wallet discovery therefore completes at confirmation. While a Receive screen
is open, Winnow can temporarily inspect relayed transactions for the displayed
scripts. This is a short-lived observation window, not an always-on mempool
subscription and not a claim of confirmation.

The interface distinguishes “observed,” “relayed,” and “seen in a block.”

### 4.4 Explorer access is a user action

A block explorer can answer quickly, but opening a transaction or address tells
that service what was requested and exposes the network connection. Winnow lets
the user select or configure an explorer for links, displays a warning first,
and permits cancellation. Explorer access is not a hidden fast path for wallet
reads.

## 5. Constructing and sending a payment

The write path begins with local UTXOs and ends at the Bitcoin P2P network.

1. Coin selection chooses confirmed spendable outputs and creates Taproot
   change when required.
2. The review screen shows destination, amount, fee, feerate, inputs, and
   change before signing.
3. The authenticated key store exposes signing material only for the signing
   operation.
4. The signed transaction is relayed to connected Bitcoin peers.
5. A bounded relay window records peer echoes as evidence of propagation, not
   confirmation.
6. Compact-filter sync later discovers the confirming block.

Winnow does not pretend to know the whole fee market without an always-on
mempool service. Its spends signal Replace-by-Fee. A fee bump creates a new
transaction that spends the same inputs at a higher fee, and history retains
the relationship between the original, intermediate replacements, and final
confirmed transaction.

The Brisa Café signet story verified a two-step replacement chain. The final
replacement confirmed and the earlier transactions remained marked as
replaced.

## 6. Taproot shared custody

### 6.1 Script-path threshold reserve

The Rivera cold reserve uses a NUMS internal key and a Taproot script leaf
containing a threshold multisignature policy. Funds cannot be spent through an
unknown key path. A valid spend reveals the selected script, control block, and
the required signatures.

PSBTv2 carries the unsigned transaction and the metadata cosigners need. Each
participant reviews the transaction before contributing a signature. The PSBT
is a coordination artifact, not an authorization service.

The public-signet story completed both Elena + Leo and Leo + Marina. That proves
the normal path and recovery path were not merely drawn in a policy editor.

### 6.2 MuSig2 joint reserve

MuSig2 is interactive. Participants aggregate public keys, exchange public
nonces, create partial signatures, and aggregate them into one Schnorr
signature. Secret nonce reuse can reveal a signing key, so Winnow treats nonce
state as one-use secret material. It lives only in the active signing screen,
is zeroed after the partial signature is created, and is abandoned if the
signer leaves before round 2.

Elena and Mateo's verified signet spend used the Taproot key path. Its witness
contained one 64-byte signature and revealed no script. This provides a useful
privacy property, but it is not a threshold recovery policy: both participants
are required.

## 7. Backup and replacement phones

A BIP39 phrase recreates deterministic keys. It does not recreate the answers a
forward-only mobile wallet has already learned: creation height, known
transactions, replacement relationships, spent outputs, and scan frontier.

Winnow therefore exports a versioned bundle. A watch-only form can transfer
public wallet state without spend authority. A seed-bearing form requires an
explicit authenticated choice and keeps the on-screen preview redacted. The
phrase itself remains copyable after authentication because a recovery secret
that cannot be moved into a user's chosen backup process is not useful custody.

On import, the replacement phone validates the bundle, reconstructs wallet
state, and verifies forward from the recorded height. The public-signet story
matched the source wallet's balance, UTXO count, transaction history,
replacement links, scan height, and peer connectivity.

An export must be protected with the same care as the authority it contains.
Winnow's public automation journal and publication pipeline exclude mnemonics,
entropy, private keys, secret nonces, and unredacted recovery screens.

## 8. Silent Payments: send works, receive is experimental

BIP352 Silent Payments give a recipient a reusable code without placing that
code or an obvious address reuse pattern on chain. Sending is self-contained:
the sender uses eligible input keys and the recipient's code to derive a unique
Taproot output.

Receiving is harder on a phone. The recipient cannot put one static output
script into a BIP158 query because each payment output is derived from the
sender's inputs. The phone must first obtain or calculate the transaction tweak,
derive candidate output scripts, and only then can those candidates be tested
against the ordinary compact filter.

Downloading every full block would remove the index dependency but would also
erase the bandwidth advantage that makes compact filters appropriate for a
phone. The current experimental JSON tweak fixture proves the algorithmic
boundary; it is not presented as a production privacy service.

The planned production direction is a block-dn-compatible provider interface:

- request fixed public block ranges rather than wallet-specific data;
- validate network, format, range, and compressed curve points;
- cache public batches locally;
- compare independent providers when available;
- derive candidates on the phone;
- use Winnow's existing BIP157/158 and full-block verification as the
  authoritative positive path; and
- never treat provider silence as cryptographic proof that no payment exists.

A provider can see the user's IP address and broad requested ranges. It can
also hide a payment by omitting a tweak. For those reasons receive remains off
by default and explicitly experimental. The current public-signet story did not
complete a Silent Payment receive, detection, export/import, and spend cycle.
That absence is a failed acceptance criterion, not a success hidden behind a
feature flag. The work is tracked in [issue 40](https://github.com/posix4e/winnow/issues/40).

## 9. Reproducible evidence

The checked-in `winnow-story` command creates an isolated simulator run,
records scenario and tool versions, launches named roles, preserves protected
state for resume, monitors public signet, and emits a safe event journal. It
does not require Bitcoin Core, RPC credentials, or an owner-machine daemon.

The August 2026 story verified these confirmed transactions:

| Story event | Public signet transaction | Result |
|---|---|---|
| First customer payment | [`44890b72…935c0`](https://explorer.bc-2.jp/tx/44890b72d9910a4ad9390a1f1e1ade446bde809ceb1736128274199e48e935c0) | Hot wallet credited |
| Final supplier RBF | [`543a9cf3…ff65`](https://explorer.bc-2.jp/tx/543a9cf35d1db26dc8b656d78a3b6c5fe88d23b4a4710883f521f6800814ff65) | Replacement confirmed |
| Cold-reserve funding | [`0e860e41…e791`](https://explorer.bc-2.jp/tx/0e860e416d346caca681f2a1b6016f9976787c363b2a4e1178bf2c07d0ebe791) | Hot wallet fed 2-of-3 reserve |
| Elena + Leo | [`46081b3d…698a`](https://explorer.bc-2.jp/tx/46081b3dfb1f841bf5642737082cb88e376cc6f967fba2109ce55991aa0e698a) | Ordinary path confirmed |
| Leo + Marina | [`7df05a81…8cbb`](https://explorer.bc-2.jp/tx/7df05a8190ccfd3ae7f39e48118616cbe210561c74d41d7f23328e86e6028cbb) | Recovery path confirmed |
| Joint-reserve funding | [`995bedd3…761c`](https://explorer.bc-2.jp/tx/995bedd34e108a9d640ebb0c005cb1519e156059086c7349918a4e1198b4761c) | MuSig2 reserve funded |
| Elena + Mateo | [`1b126138…dc03`](https://explorer.bc-2.jp/tx/1b1261381ae44e1d3a0d99bfbc2bb9d428223a45f2a26642b0fcf7a17c51dc03) | Key-path spend confirmed |

The complete safe summary is published on the [evidence page](evidence.html).
Media remains behind a separate human review because automated text scanning
cannot guarantee that recovery words never appear in a video frame.

## 10. Limitations and non-goals

- **Not a full node.** Winnow does not validate every transaction and consensus
  rule in every block.
- **Not anonymous networking.** Direct peers and optional services see an IP
  connection unless the surrounding network supplies additional privacy.
- **Not instant finality.** A mempool observation can be useful, but only a
  block supplies confirmation.
- **Not arbitrary legacy wallet recovery.** Forward-oriented import depends on
  a Winnow bundle; broad descriptor rescans are separate work.
- **Not a custody company.** The software expresses keys and policies. It does
  not authenticate heirs, resolve disputes, or replace legal planning.
- **Not completed Silent Payment receiving.** Sending is implemented;
  production mobile receiving remains experimental and incomplete.
- **Not mainnet release evidence.** Signet proves integration with a public
  Bitcoin test network, not readiness to hold valuable mainnet funds.

## 11. Roadmap

The immediate engineering priorities are:

1. finish the block-dn-compatible Silent Payment receive backend, provider
   comparison, cache validation, reorg handling, and a fresh public-signet
   receive-and-spend story;
2. continue peer-pool hardening and make damaged local data distinct from
   remote peer failure in every synchronization surface;
3. complete mainnet-oriented security review and controlled low-value testing;
4. expand interoperable descriptor and hardware-signer workflows without
   weakening the review-before-sign boundary; and
5. keep every public claim tied to reproducible evidence rather than a static
   feature checklist.

## Primary references

- [BIP141 — Segregated Witness](https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki)
- [BIP157 — Client Side Block Filtering](https://github.com/bitcoin/bips/blob/master/bip-0157.mediawiki)
- [BIP158 — Compact Block Filters for Light Clients](https://github.com/bitcoin/bips/blob/master/bip-0158.mediawiki)
- [BIP174 — Partially Signed Bitcoin Transaction Format](https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki)
- [BIP341 — Taproot](https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki)
- [BIP342 — Validation of Taproot Scripts](https://github.com/bitcoin/bips/blob/master/bip-0342.mediawiki)
- [BIP327 — MuSig2](https://github.com/bitcoin/bips/blob/master/bip-0327.mediawiki)
- [BIP352 — Silent Payments](https://github.com/bitcoin/bips/blob/master/bip-0352.mediawiki)
- [BIP370 — PSBT Version 2](https://github.com/bitcoin/bips/blob/master/bip-0370.mediawiki)
- [Winnow source and test suite](https://github.com/posix4e/winnow)

---

Winnow's proposition is not that a phone can eliminate trust. It is that the
wallet can make trust smaller, visible, and appropriate to the money: local
keys for today's coffee, a threshold for business savings, joint authorization
for family funds, and plain warnings wherever the phone needs outside help.
