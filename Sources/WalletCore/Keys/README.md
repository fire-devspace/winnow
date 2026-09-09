[Back to main README](../../../README.md)

# Wallet keys and secret storage

BIP39 recovery words, BIP32 derivation, BIP86 addresses, and the Apple Keychain
implementation live together. Receiving, recovery, and signing use the same
keys; durable secrets retain access rules distinct from ordinary wallet metadata.
Seed derivation normalizes the recovery words and the passphrase NFKD, as BIP39
requires: any other normalization derives a seed no other wallet agrees with, and
nothing about the phrase itself would look wrong.

A `WalletSecret` is a recovery phrase, a master extended private key, or — this
fork adds the third shape — the account extended private key at the descriptor's
own origin path, held beside the fingerprint of the master it came from. That
case lets an embedder derive m/86'/coin'/account' in its own key service and
hand the library nothing above it, so a device that is read yields one account's
spending authority rather than every account's and no recovery phrase; upstream
stores a root secret and has no caller that could reach the case.
`Wallet.create(accountKey:masterFingerprint:…)` is the constructor that stores
one, and a wallet holding one cannot export a seed backup.

The fingerprint travels with the key because an extended key records its
parent's fingerprint, not the master's, and the wallet ID and every PSBT origin
are the master fingerprint under either custody. Signing walks a root secret
down the origin path exactly as it did before and uses an account secret where
it already stands: that path is hardened, so walking it a second time would
derive a different key rather than fail. The fingerprint and the key's depth are
checked before anything is signed, and whichever shape was held, the key that
will sign is compared against the account key the descriptor carries. That last
check is what a secret cannot answer about itself: a KeyStore entry is filed
under the wallet ID and the ID is a fingerprint, so a key belonging to someone
else can sit where this wallet's belongs and derive a signature that is valid
for coins this wallet does not own. The differential test in
[WalletCore tests](../../../Tests/WalletCoreTests/README.md) compares the two
custody shapes byte for byte — addresses, signing keys, signatures and PSBT
origins — across account indices and both networks.

Only the account case carries a version in its header (`account/1`). Upstream's
two headers are bare words because builds that write and read them have shipped;
this one has shipped nowhere, so it can say from its first byte which shape the
lines beneath are in, and a build that meets a version it has no rules for
refuses it by name instead of reading them as the shape it knows. The
fingerprint line is written lowercase and only read lowercase, so one key has
exactly one encoding.

The [wallet](../Wallet/README.md), [signer](../Transactions/README.md), and
[app](../../WinnowApp/README.md) use this code. The in-memory keystore stays in
[TestSupport](../../../Tests/Support/README.md), outside production sources.

[BIP39](../../../Tests/BitcoinCoreTests/BIP39Tests.swift),
[BIP32](../../../Tests/BitcoinCoreTests/BIP32Tests.swift), and
[BIP86](../../../Tests/BitcoinCoreTests/BIP86Tests.swift) check independent vectors.
[KeyStore tests](../../../Tests/WalletCoreTests/KeyStoreTests.swift),
[Keychain attributes](../../../AppTests/KeychainAttributeTests.swift), and
[device authentication](../../../AppTests/DeviceAuthenticationTests.swift) check
storage and app integration. Device-lock enforcement needs physical-device evidence.
