# Current selectors for historical test evidence

The September 2026 consolidation moved tests without dropping their names.
Dated findings and invariant evidence keep the commands and type names used
for those runs. To repeat a historical suite on the current tree, use
`swift test --filter` with its current suite below; a combined suite runs
additional related tests. The Xcode AppTests class names are unchanged.

| Historical SwiftPM suite | Current suite |
| --- | --- |
| `VaultFlowTests`, `VaultThresholdTests`, `PSBTMultisigTests` | `VaultSpendTests` |
| `VaultCosignerIdentityTests`, `VaultDraftIdentityTests`, `VaultSignerIndependenceTests` | `VaultAdmissionTests` |
| `SpentCoinTombstoneTests`, `ReorgRollbackTests` | `WalletReorgTests` |
| `CoinSelectionPropertyTests`, `FeePolicyTests` | `CoinSelectionTests` |
| `AntiFeeSnipingTests` | `TransactionBuilderTests` |
| `ImportBundleBoundsTests` | `ImportBundleTests` |
| `SighashBIP341ScriptPathTests` | `SighashBIP341Tests` |
| `LoopbackTests`, `FilterSyncPersistenceTests`, `FilterProgressRollbackTests`, `FilterMatchingTests` | `FilterSyncTests` |
| `CheckpointMajorityTests`, `PeerDisagreementTests`, `CrossSourceCheckTests`, `CheckpointHangupTests` | `FilterSyncAdversaryTests` |
| `PeerCooldownTests`, `StaleTipEvictionTests`, `SocksProxyTests` | `PeerPoolTests` |
| `PeerDiversityTests`, `SeedResolverTests`, `FallbackPeerListTests` | `PeerPolicyTests` |
| `MainnetCheckpointTests`, `CheckpointStartTests`, `HeaderStartPolicyTests`, `HeaderReplayTests`, `ReorgVisibilityTests` | `HeaderChainTests` |
| `HeaderStorageAppendTests`, `HeaderStorageCorruptionTests`, `HeaderStorageBoundsTests` | `HeaderStorageTests` |
| `TxBroadcasterBackoffTests`, `FeeFilterAnnouncementTests` | `TxBroadcasterTests` |
| `TxBroadcasterReorgTests` | `TxBroadcasterStoreTests` |
| `WireFormatTests`, `MessageTests`, `FramingTests` | `WireTests` |

The store-persistence cases formerly in `TxBroadcasterTests` are now in
`TxBroadcasterStoreTests`; relay cases remain in `TxBroadcasterTests`.
`MuSig2SessionSafetyTests` retains its type, now in `MuSig2Tests.swift`.
`WinnowGenerateTests` and the fuzz suite retain their names in `ToolsTests`.
The demo/story tests were retired with that feature; the subprocess
output-drain regression is retained in `DebugSystemTests`. The unused `BlockchainBackend` module and its two
Esplora/disclosure suites were subsequently removed: their four tests covered
only the deleted client, not GUI explorer links or wallet networking.

Historical `WinnowSoak` runs used the standalone executable. The same driver
now runs as `swift run winnow-debug soak`; `winnow-generate` commands now use
`swift run winnow-debug generate`. Neither command migration rewrites the
recorded dates, measurements, or scope of historical evidence.

## Wallet/network consolidation

The current WalletCore target contains the former BitcoinP2P target.
Its protocol tests now live in Tests/WalletCoreTests/Network and use the
WalletCoreTests target; their suite names and assertions remain. Shared vector
resources are in Tests/WalletCoreTests/Vectors. Historical audit records above
keep the module and path names of the revision they describe.

See ../testing.md for the current user-journey ownership policy. The obsolete
one-shot Wallet.send test and staged StorefrontCaptureTests were retired;
actual app receipt and fee-replacement journeys take their place. The Core
full-loop checks still exercise consensus and replacement policy.
