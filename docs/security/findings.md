# Security findings register

This public register contains fixed findings and sanitized open risks. Details
that would enable exploitation before a fix belong in a private GitHub security
advisory, not here.

| ID | Severity | Invariant | Status | Summary | Evidence |
|---|---|---|---|---|---|
| SEC-001 | Medium | S7, S10 | Fixed on `codex/security-hardening-100-phase0` | PSBT import trusted attacker-controlled CompactSize values when converting to native integers and had no document/map budget. A malicious cosigning document could terminate the importing process. Raw and Base64 sizes, map keys/pairs, input/output counts, and fixed-width known fields are now bounded and validated before use. | `PSBTTests.hostileLengths`; targeted AddressSanitizer run; full 311-test run; iOS simulator build |
| SEC-002 | Low | S12 | Fixed on `codex/security-hardening-100-phase0` | The application manifest pinned the secp package by version, but `.gitignore` excluded the resolved source revision. `Package.resolved` now records the audited dependency commit. | `Package.resolved`; clean package resolution and app build |
| SEC-003 | High | S2 | Fixed on `codex/security-send-review-binding` | Payment and fee-replacement reviews were not bound to every live authorization input or late async response. Reviews are now invalidated on edits, obsolete responses are discarded, and signing uses the immutable request that produced the visible review. | `SendReviewBindingTests`; 310 package tests; 7 iOS app tests; draft PR #102 |
| SEC-004 | High | S2, S8, S9 | Fixed on `codex/security-vault-psbt-validation` | Vault review treated untrusted PSBT output derivation metadata as proof that an output was change and did not centrally validate the known input amount/script and descriptor policy before each action. Review now derives ownership from actual descriptor scripts and rejects unknown, duplicated, altered, non-output-committing, or economically invalid proposals before display, signing, finalization, or broadcast. | `VaultFlowTests.vaultSpendReview`; 312 package tests; 6 vault tests under AddressSanitizer; clean iOS app test build |

## Open release risks (not vulnerability claims)

These are gaps in required evidence and remain release-blocking under epic
#100 even when no concrete exploit has been established:

- S1: iOS Keychain, device-authentication, clipboard, screenshot/background,
  and release-artifact secret-containment checks are incomplete.
- S2: the fixed send/RBF and vault boundaries still need UI automation,
  double-submit/interruption tests, and an independent review.
- S4: MuSig2 nonce interruption/replay/concurrency coverage is incomplete.
- S5/S10: sustained hostile-peer, sanitizer, and fuzz evidence is incomplete.
- S12: CI actions, artifact provenance, independent review, and the written
  limited-mainnet gate remain incomplete.

## Validation record

| Date | Source | Command | Result |
|---|---|---|---|
| 2026-08-21 | `98d9056` baseline | `swift test` | 310 tests / 60 suites passed; environment-gated suites skipped |
| 2026-08-21 | Phase 0 working tree | `swift test --filter PSBTTests` | 6 tests / 1 suite passed |
| 2026-08-21 | Phase 0 working tree | `swift test --sanitize=address --filter PSBTTests` | 6 tests / 1 suite passed under AddressSanitizer |
| 2026-08-21 | Phase 0 working tree | `swift test` | 311 tests / 60 suites passed; environment-gated suites skipped |
| 2026-08-21 | Phase 0 working tree | `xcodegen && xcodebuild ... generic/platform=iOS Simulator ... build` | Build succeeded for arm64 and x86_64 simulator |
| 2026-08-21 | Vault-validation stack | `swift test` | 312 tests / 60 suites passed; environment-gated suites skipped |
| 2026-08-21 | Vault-validation stack | `swift test --sanitize=address --filter VaultFlowTests` | 6 tests / 1 suite passed under AddressSanitizer |
| 2026-08-21 | Vault-validation stack | clean DerivedData `xcodebuild ... -only-testing:WinnowAppTests test` | App compiled; 4 iOS app tests passed |
