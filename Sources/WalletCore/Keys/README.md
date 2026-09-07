[Back to main README](../../../README.md)

# Wallet secret storage

KeyStore defines the wallet's secret-storage interface, and KeychainStore supplies
its Apple Keychain implementation. Recovery and signing need durable secrets
with access rules that are distinct from ordinary wallet metadata.

The [wallet](../Wallet/README.md) and
[app](../../WinnowApp/README.md) consume this code.
The in-memory implementation used by tests lives in
[TestSupport](../../../Tests/Support/README.md), outside production sources.

[KeyStore tests](../../../Tests/WalletCoreTests/KeyStoreTests.swift) check the interface,
while [Keychain attribute tests](../../../AppTests/KeychainAttributeTests.swift) and
[device authentication tests](../../../AppTests/DeviceAuthenticationTests.swift) check
app integration. Device-lock enforcement still needs physical-device evidence.
