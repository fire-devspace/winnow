# Features, journeys, and evidence

The supported product is the real iPhone app plus explicit debugging tools.
Everyday and advanced journeys are declared in docs/journeys.json. The homepage
and advanced page are generated from that file and the actual app test source
by scripts/build-site. The public roadmap owns future work; it is not evidence
that a feature ships.

## What earns a place

- A user-facing feature needs a documented journey through the real app.
  Include its review, failure, interruption, or recovery behavior where those
  affect the promise. Advanced features follow the same rule.
- A debugging command needs a concrete diagnostic purpose, a runbook, and
  meaningful command/protocol checks. Help output alone does not prove a live
  network operation.
- A lower-level component must serve one of those purposes or enforce a named
  security property. Do not add a production API just to make a test convenient.
- Delete obsolete features with their tests. Delete duplicate happy-path tests
  when the actual app journey and relevant independent checks cover the promise.
  Keep vectors, adversarial cases, arithmetic bounds, storage integrity,
  authorization, and recovery regressions when their invariant still exists.

## Architecture follows the app

WalletCore now owns wallet state, transaction construction, peer connections,
headers, filters, and relay in one package target. The app directly orchestrates
those parts; there is no extra wallet/network facade or parallel library-only
send/scan workflow. BitcoinCore remains the pure cryptographic and descriptor
implementation. Actors retain their existing ownership and lifetimes.

InMemoryKeyStore belongs to TestSupport, not the shipping wallet. The module
version placeholders and duplicate binary serializers are removed. There is one
app release version.

## Which tests say what

- UITests drives setup/backup, receipt, send, recovery/export, people, shared
  savings, beginner controls, advanced approvals, group signing, fee replacement,
  and disclosure controls. CI runs the complete ordered suite for app/protocol
  changes on same-repository pull requests and main, as well as scheduled runs.
- AppTests checks protected actions, review invalidation, persisted state,
  network separation, and OS integration around those journeys.
- WalletCoreTests checks wallet/network invariants and hostile peer behavior.
  The former BitcoinP2PTests are grouped under WalletCoreTests/Network.
- BitcoinCoreTests retains independent vectors and parser/cryptographic bounds.
- DifferentialTests asks Bitcoin Core to judge transactions, replacement policy,
  envelopes, and cosigning. The full-loop fixture uses prepare, relay, commit;
  it no longer requires an alternate production send API.
- ToolsTests and the fuzz harness cover debugging commands and hostile inputs.

The old convenience-send test and staged storefront sequence are retired.
Unconfirmed receipts and fee replacement now have focused app journeys.
Screenshots come from these tests, not a second demonstration script.

## What generated pages do and do not establish

Generation refuses a missing test selector, an app scenario with no documented
journey, or a screenshot that its linked scenarios do not capture. This catches
documentation drift; it is not runtime coverage analysis or proof that every
line executed. A supported feature still needs a passing app run and the
relevant invariant tests before merging. Do not replace an assertion with a
screenshot or infer success from the presence of an image.

CI's xcresult bundle and logs are authoritative for success, failure, and the
tested revision. Timings include only the current process's observations;
partial runs never inherit older scenarios under a new timestamp. Captures go
to CI artifacts or fresh temporary directories, not directly into public docs.
Only deliberately selected, reviewed test images belong on the site. Historical
images, audit notes, and findings retain their historical status.

Simulator tests do not establish locked-device Keychain enforcement, battery
life, real-world peer independence, or independent review. Keep those limitations
explicit. Future work belongs on the separate roadmap.
