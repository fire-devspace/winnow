# Security findings register

This public register contains fixed findings and sanitized open risks. Details
that would enable exploitation before a fix belong in a private GitHub security
advisory, not here.

| ID | Severity | Invariant | Status | Summary | Evidence |
|---|---|---|---|---|---|
| SEC-001 | Medium | S7, S10 | Fixed on `codex/security-hardening-100-phase0` | PSBT import trusted attacker-controlled CompactSize values when converting to native integers and had no document/map budget. A malicious cosigning document could terminate the importing process. Raw and Base64 sizes, map keys/pairs, input/output counts, and fixed-width known fields are now bounded and validated before use. | `PSBTTests.hostileLengths`; targeted AddressSanitizer run; full 311-test run; iOS simulator build |
| SEC-002 | Low | S12 | Fixed on `codex/security-hardening-100-phase0` | The application manifest pinned the secp package by version, but `.gitignore` excluded the resolved source revision. `Package.resolved` now records the audited dependency commit. | `Package.resolved`; clean package resolution and app build |

## Open release risks (not vulnerability claims)

These are gaps in required evidence and remain release-blocking under epic
#100 even when no concrete exploit has been established:

- S1: iOS Keychain, device-authentication, clipboard, screenshot/background,
  and release-artifact secret-containment checks are incomplete.
- S2: transaction review has not yet been tested against every mutation and
  stale-review path across the UI-to-signer boundary.
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
