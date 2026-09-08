[Back to main README](../../README.md)

# The iPhone wallet

SwiftUI screens and AppModel turn wallet and network state into receiving,
sending, recovery, saved recipients, and shared accounts. The app owns user review,
authentication, presentation, and lifecycle; WalletCore owns the Bitcoin rules.

Wallet is the one account and transaction list. Payment details save or rename a
recipient; Send holds the saved-recipient picker. Removing a shortcut preserves
past labels, signer identities, and fresh-address counters in the existing
people.json store. Receive shares the wallet’s payment card.

[Documented journeys](../../docs/journeys.json) identify the supported experiences.
[App tests](../../AppTests/README.md) check state and protected actions;
[UI tests](../../UITests/README.md) drive the simulator against a disposable node.
Simulator tests do not establish physical-device lock behavior or battery life.

Assets.xcassets contains the app icon and its Xcode metadata; it is an asset bundle,
not another code layer. [make-icon.swift](../../scripts/make-icon.swift) creates icon
artwork; changing it requires inspecting the rendered icon and building the app.
Keep documentation outside the asset catalog so it is not treated as an asset.
